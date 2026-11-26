import Foundation
import AVFoundation
import AppKit
import ScreenCaptureKit

/// Records calls with ScreenCaptureKit: system audio (any call tool)
/// plus microphone, with or without screen video. The finished file is
/// saved into the watched folder and queued for the pipeline
/// (transcription → notes → compression).
@MainActor
final class CallRecorder: NSObject, ObservableObject {
    enum Mode {
        case videoAudio
        case audioOnly
    }

    static let shared = CallRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var audioWriter: AudioOnlyWriter?
    private var micCapture: MicCapture?
    private var tempURL: URL?
    private var finalURL: URL?
    /// Resolved when SCRecordingOutput finishes finalizing the file.
    private var finishSignal: CheckedContinuation<Void, Never>?

    fileprivate func resolveFinishSignal() {
        finishSignal?.resume()
        finishSignal = nil
    }

    func start(mode: Mode, filter customFilter: SCContentFilter? = nil) async {
        // Preflight: no permission → explain and route to System Settings.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showPermissionAlert()
            return
        }
        do {
            try await begin(mode, customFilter: customFilter)
        } catch {
            appLog("❌ Recording not started: \(error.localizedDescription)")
            showErrorAlert(message: error.localizedDescription)
        }
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Screen recording permission required")
        alert.informativeText = String(localized: "To record calls, CallT needs permission to capture the screen and system audio. Enable CallT in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    private func showErrorAlert(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Recording could not start")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private func begin(_ mode: Mode, customFilter: SCContentFilter? = nil) async throws {
        guard !isRecording else { return }

        let filter: SCContentFilter
        var captureSize: CGSize
        if let customFilter {
            filter = customFilter
            captureSize = customFilter.contentRect.size
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                throw TranscriptionError(message: String(localized: "no display available"))
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            captureSize = CGSize(width: display.width, height: display.height)
        }
        if captureSize.width < 2 || captureSize.height < 2 {
            captureSize = CGSize(width: 1280, height: 720)
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        // Il microfono NON si prende con ScreenCaptureKit: SCK si impossessa
        // del dispositivo di ingresso e rompe la Voice Processing dell'app
        // della call (echo cancellation). In modalità solo-audio usiamo
        // AVCapture (MicCapture), che legge lo stesso dispositivo senza
        // riconfigurarlo. In modalità video SCRecordingOutput vuole il mic
        // dentro lo stream, quindi lì resta SCK.
        let wantsMic = AppSettings.captureMic != "never"
        config.captureMicrophone = false
        switch mode {
        case .videoAudio:
            // 1x resolution (points): plenty for calls, lighter files.
            config.width = Int(captureSize.width)
            config.height = Int(captureSize.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            config.showsCursor = true
            config.captureMicrophone = wantsMic
        case .audioOnly:
            // No video output is ever written: the stream's video stays at
            // the bare minimum and is discarded.
            config.width = 64
            config.height = 64
            config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)

        let watch = AppSettings.watchFolder
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        let stamp = Self.nameFormatter.string(from: Date())
        let baseName = String(localized: "Recording")

        switch mode {
        case .videoAudio:
            // Hidden name (leading ".") while writing: the watcher ignores it.
            let temp = watch.appendingPathComponent(".recording-in-progress.mp4")
            try? FileManager.default.removeItem(at: temp)
            let recConfig = SCRecordingOutputConfiguration()
            recConfig.outputURL = temp
            recConfig.videoCodecType = .hevc
            let output = SCRecordingOutput(configuration: recConfig, delegate: self)
            try newStream.addRecordingOutput(output)
            recordingOutput = output
            tempURL = temp
            finalURL = watch.appendingPathComponent("\(baseName) \(stamp).mp4")
        case .audioOnly:
            let temp = watch.appendingPathComponent(".recording-in-progress.m4a")
            let writer = try AudioOnlyWriter(url: temp, withMic: wantsMic)
            try newStream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            // Il microfono entra da AVCapture, su un percorso audio separato:
            // nessuna interferenza con il dispositivo usato dalla call.
            // Parte dopo startCapture, così la traccia di sistema definisce
            // l'istante zero del file.
            if wantsMic { micCapture = MicCapture() }
            audioWriter = writer
            tempURL = temp
            finalURL = watch.appendingPathComponent("\(baseName) \(stamp).m4a")
        }

        try await newStream.startCapture()
        stream = newStream
        if let mic = micCapture, let writer = audioWriter {
            let started = mic.start(onBuffer: { buffer in writer.appendMic(buffer) })
            if !started { micCapture = nil }
        }
        isRecording = true
        startedAt = Date()
        AppSettings.defaults.set(mode == .audioOnly ? "audioOnly" : "videoAudio", forKey: "lastRecordMode")
        RecordingHUD.shared.show()
        appLog("🔴 Recording started (\(mode == .videoAudio ? "video and audio" : "audio only"))")
    }

    func stop() async {
        guard isRecording else { return }

        if recordingOutput != nil {
            // SCRecordingOutput finalizes the file asynchronously after
            // stopCapture: wait for recordingOutputDidFinishRecording
            // (with a timeout) before touching the file, or the move races
            // the finalizer and fails.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                finishSignal = cont
                Task { @MainActor in
                    try? await self.stream?.stopCapture()
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    self.resolveFinishSignal()  // timeout fallback; no-op if already resolved
                }
            }
        } else {
            try? await stream?.stopCapture()
        }
        stream = nil
        recordingOutput = nil
        micCapture?.stop()
        micCapture = nil
        if let audioWriter {
            await audioWriter.finish()
            self.audioWriter = nil
        }
        isRecording = false
        startedAt = nil
        RecordingHUD.shared.hide()

        if let tempURL, let finalURL {
            // Extra safety: the file can appear a moment after finalization.
            for _ in 0..<10 where !FileManager.default.fileExists(atPath: tempURL.path) {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            do {
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
                appLog("⏹️ Recording saved: \(finalURL.lastPathComponent)")
                // Queue right away, without depending on folder monitoring.
                AppState.shared.enqueue(finalURL)
            } catch {
                appLog("❌ Saving the recording failed: \(error.localizedDescription)")
            }
        }
        tempURL = nil
        finalURL = nil
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()
}

extension CallRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in CallRecorder.shared.resolveFinishSignal() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        appLog("❌ Recording error: \(error.localizedDescription)")
        Task { @MainActor in
            CallRecorder.shared.resolveFinishSignal()
            await CallRecorder.shared.stop()
        }
    }
}

/// Writer for audio-only mode: one .m4a file with one or two AAC tracks
/// (system audio, plus the microphone when it is available). The screen is
/// never written to disk.
final class AudioOnlyWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.werootbox.callt.recording.audio")
    private let writer: AVAssetWriter
    private let systemInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var micAppendFailed = false

    init(url: URL, withMic: Bool = true) throws {
        try? FileManager.default.removeItem(at: url)
        // fileType .mp4 (ISO-BMFF, same family as M4A) so two tracks can be written.
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        systemInput.expectsMediaDataInRealTime = true
        writer.add(systemInput)
        if withMic {
            let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            mic.expectsMediaDataInRealTime = true
            writer.add(mic)
            micInput = mic
        } else {
            micInput = nil
        }
        super.init()
        guard writer.startWriting() else {
            throw writer.error ?? TranscriptionError(message: "could not open the audio file")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        append(sampleBuffer, to: systemInput)
    }

    /// Microfono da AVCapture: arriva su un'altra coda, ma entra nella coda del
    /// writer così `startSession` viene chiamata una volta sola e l'ordine dei
    /// due percorsi resta deterministico.
    func appendMic(_ buffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self, let mic = self.micInput else { return }
            self.append(buffer, to: mic, isMic: true)
        }
    }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput, isMic: Bool = false) {
        guard CMSampleBufferIsValid(buffer), CMSampleBufferGetNumSamples(buffer) > 0 else { return }
        if !sessionStarted {
            sessionStarted = true
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
        }
        // Real time: se il writer è indietro il buffer si scarta.
        guard input.isReadyForMoreMediaData else { return }
        if !input.append(buffer), isMic, !micAppendFailed {
            micAppendFailed = true
            appLog("⚠️ Microfono non allineabile nella traccia: continuo con il solo audio di sistema (\(writer.error?.localizedDescription ?? "formato non compatibile"))")
        }
    }

    func finish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.sessionStarted {
                    self.systemInput.markAsFinished()
                    self.micInput?.markAsFinished()
                    self.writer.finishWriting { cont.resume() }
                } else {
                    self.writer.cancelWriting()
                    cont.resume()
                }
            }
        }
    }
}
