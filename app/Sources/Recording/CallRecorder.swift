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
    private var tempURL: URL?
    private var finalURL: URL?

    func start(mode: Mode) async {
        // Preflight: no permission → explain and route to System Settings.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showPermissionAlert()
            return
        }
        do {
            try await begin(mode)
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

    private func begin(_ mode: Mode) async throws {
        guard !isRecording else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw TranscriptionError(message: String(localized: "no display available"))
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = true
        switch mode {
        case .videoAudio:
            // 1x resolution (points): plenty for calls, lighter files.
            config.width = display.width
            config.height = display.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            config.showsCursor = true
        case .audioOnly:
            // No video output is ever written: the stream's video stays at
            // the bare minimum and is discarded.
            config.width = 64
            config.height = 64
            config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
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
            let writer = try AudioOnlyWriter(url: temp)
            try newStream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            try newStream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
            audioWriter = writer
            tempURL = temp
            finalURL = watch.appendingPathComponent("\(baseName) \(stamp).m4a")
        }

        try await newStream.startCapture()
        stream = newStream
        isRecording = true
        startedAt = Date()
        appLog("🔴 Recording started (\(mode == .videoAudio ? "video and audio" : "audio only"))")
    }

    func stop() async {
        guard isRecording else { return }
        try? await stream?.stopCapture()
        stream = nil
        recordingOutput = nil
        if let audioWriter {
            await audioWriter.finish()
            self.audioWriter = nil
        }
        isRecording = false
        startedAt = nil

        if let tempURL, let finalURL {
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
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        appLog("❌ Recording error: \(error.localizedDescription)")
        Task { @MainActor in await CallRecorder.shared.stop() }
    }
}

/// Writer for audio-only mode: one .m4a file with two AAC tracks
/// (system audio + microphone). The screen is never written to disk.
final class AudioOnlyWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.werootbox.callt.recording.audio")
    private let writer: AVAssetWriter
    private let systemInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput
    private var sessionStarted = false

    init(url: URL) throws {
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
        micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        systemInput.expectsMediaDataInRealTime = true
        micInput.expectsMediaDataInRealTime = true
        writer.add(systemInput)
        writer.add(micInput)
        super.init()
        guard writer.startWriting() else {
            throw writer.error ?? TranscriptionError(message: "could not open the audio file")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, type == .audio || type == .microphone else { return }
        if !sessionStarted {
            sessionStarted = true
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        let input = type == .audio ? systemInput : micInput
        // Real time: drop the buffer if the writer is behind.
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.sessionStarted {
                    self.systemInput.markAsFinished()
                    self.micInput.markAsFinished()
                    self.writer.finishWriting { cont.resume() }
                } else {
                    self.writer.cancelWriting()
                    cont.resume()
                }
            }
        }
    }
}
