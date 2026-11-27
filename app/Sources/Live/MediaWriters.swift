import Foundation
import AVFoundation
import CoreMedia

/// Scrive un file .mp4/.m4a con traccia video opzionale (HEVC), audio di
/// sistema e microfono su tracce AAC separate. Sostituisce SCRecordingOutput,
/// che voleva il microfono dentro lo stream di ScreenCaptureKit.
///
/// Un append rifiutato manderebbe in errore l'intero file: per questo ogni
/// traccia scarta i buffer fuori ordine o precedenti all'inizio della sessione.
final class MediaFileWriter: @unchecked Sendable {
    let url: URL
    let queue: DispatchQueue
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let systemInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput?
    private(set) var sessionStart: CMTime?
    private(set) var lastPTS: CMTime = .invalid
    private var lastByInput: [ObjectIdentifier: CMTime] = [:]
    private var failedLogged = false

    init(url: URL, videoSize: CGSize?, withMic: Bool, fps: Int = 10, queue: DispatchQueue? = nil) throws {
        self.url = url
        self.queue = queue ?? DispatchQueue(label: "com.werootbox.callt.writer.\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false

        if let size = videoSize, size.width >= 16 {
            let bitrate = max(800_000, Int(size.width * size.height * Double(fps) * 0.07))
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                ],
            ])
            video.expectsMediaDataInRealTime = true
            writer.add(video)
            videoInput = video
        } else {
            videoInput = nil
        }

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
        guard writer.startWriting() else {
            throw writer.error ?? TranscriptionError(message: "could not open \(url.lastPathComponent)")
        }
    }

    var hasVideo: Bool { videoInput != nil }

    // Da chiamare sulla `queue` del writer.
    func appendVideo(_ buffer: CMSampleBuffer) { if let videoInput { append(buffer, to: videoInput) } }
    func appendSystem(_ buffer: CMSampleBuffer) { append(buffer, to: systemInput) }
    func appendMic(_ buffer: CMSampleBuffer) { if let micInput { append(buffer, to: micInput) } }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        guard writer.status == .writing, CMSampleBufferIsValid(buffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid else { return }
        if sessionStart == nil {
            sessionStart = pts
            writer.startSession(atSourceTime: pts)
        }
        guard let start = sessionStart, pts >= start else { return }
        let key = ObjectIdentifier(input)
        if let previous = lastByInput[key], pts <= previous { return }
        // Tempo reale: se l'encoder è indietro il buffer si scarta.
        guard input.isReadyForMoreMediaData else { return }
        if input.append(buffer) {
            lastByInput[key] = pts
            if !lastPTS.isValid || pts > lastPTS { lastPTS = pts }
        } else if !failedLogged {
            failedLogged = true
            appLog("⚠️ Writing \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "append failed")")
        }
    }

    /// Chiude il file. Ritorna true se il file è valido.
    func finish() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async {
                guard self.sessionStart != nil, self.writer.status == .writing else {
                    self.writer.cancelWriting()
                    cont.resume(returning: false)
                    return
                }
                self.videoInput?.markAsFinished()
                self.systemInput.markAsFinished()
                self.micInput?.markAsFinished()
                if self.lastPTS.isValid { self.writer.endSession(atSourceTime: self.lastPTS) }
                self.writer.finishWriting {
                    cont.resume(returning: self.writer.status == .completed)
                }
            }
        }
    }
}

/// Buffer circolare per le mini registrazioni: scrive di continuo segmenti
/// HEVC da ~10 s in una cartella temporanea e tiene solo gli ultimi.
/// Una clip unisce i segmenti che coprono [t − prima, t + dopo].
final class ClipRingBuffer: @unchecked Sendable {
    private struct Segment {
        let url: URL
        let start: Double   // PTS in secondi
        var end: Double
    }

    private let dir: URL
    private let videoSize: CGSize
    private let withMic: Bool
    private let fps: Int
    private let segmentSeconds: Double = 10
    private let keepSeconds: Double
    private let queue = DispatchQueue(label: "com.werootbox.callt.live.clips")
    private var current: MediaFileWriter?
    private var currentStart: Double = 0
    private var segments: [Segment] = []
    private var finishing: [Task<Void, Never>] = []
    private var pendingClips = 0
    private var counter = 0

    init(dir: URL, videoSize: CGSize, withMic: Bool, fps: Int, maxPreRoll: Double) {
        self.dir = dir
        self.videoSize = videoSize
        self.withMic = withMic
        self.fps = fps
        self.keepSeconds = maxPreRoll + 20
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func appendVideo(_ buffer: CMSampleBuffer) {
        queue.async { [self] in
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if current == nil || pts - currentStart >= segmentSeconds {
                rotate(startingAt: pts)
            }
            current?.appendVideo(buffer)
            if let index = segments.indices.last { segments[index].end = max(segments[index].end, pts) }
        }
    }

    func appendSystem(_ buffer: CMSampleBuffer) {
        queue.async { [self] in current?.appendSystem(buffer) }
    }

    func appendMic(_ buffer: CMSampleBuffer) {
        queue.async { [self] in current?.appendMic(buffer) }
    }

    /// Da chiamare sulla coda: chiude il segmento corrente e (se `pts`) ne apre uno nuovo.
    private func rotate(startingAt pts: Double?) {
        if let old = current {
            current = nil
            finishing.append(Task { _ = await old.finish() })
        }
        if let pts {
            counter += 1
            let url = dir.appendingPathComponent(String(format: "seg-%05d.mp4", counter))
            if let writer = try? MediaFileWriter(url: url, videoSize: videoSize, withMic: withMic,
                                                 fps: fps, queue: queue) {
                current = writer
                currentStart = pts
                segments.append(Segment(url: url, start: pts, end: pts))
            }
        }
        prune(now: pts ?? currentStart)
    }

    private func prune(now: Double) {
        guard pendingClips == 0 else { return }
        while let first = segments.first, segments.count > 2, now - first.end > keepSeconds {
            try? FileManager.default.removeItem(at: first.url)
            segments.removeFirst()
        }
    }

    /// Crea la clip attorno all'istante `center` (PTS in secondi). Attende che
    /// passino i secondi "dopo", poi esporta. Ritorna l'URL del file creato.
    func makeClip(center: Double, before: Double, after: Double, to output: URL) async throws -> URL {
        queue.sync { pendingClips += 1 }
        defer { queue.async { self.pendingClips -= 1 } }
        try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))

        // Chiude il segmento in corso così il materiale recente è leggibile.
        let waits: [Task<Void, Never>] = queue.sync {
            rotate(startingAt: nil)
            let list = finishing
            finishing.removeAll()
            return list
        }
        for task in waits { await task.value }

        let from = center - before
        let to = center + after
        let chosen: [Segment] = queue.sync {
            segments.filter { $0.end >= from && $0.start <= to }
        }
        guard let base = chosen.first?.start else {
            throw TranscriptionError(message: "no video available for the clip yet")
        }

        let composition = AVMutableComposition()
        var tracks: [String: AVMutableCompositionTrack] = [:]
        for segment in chosen {
            let asset = AVURLAsset(url: segment.url)
            guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            let at = CMTime(seconds: segment.start - base, preferredTimescale: 600)
            for media in [AVMediaType.video, .audio] {
                let sourceTracks = (try? await asset.loadTracks(withMediaType: media)) ?? []
                for (index, source) in sourceTracks.enumerated() {
                    let key = "\(media.rawValue)-\(index)"
                    if tracks[key] == nil {
                        tracks[key] = composition.addMutableTrack(
                            withMediaType: media, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    try? tracks[key]?.insertTimeRange(range, of: source, at: at)
                }
            }
        }
        let total = composition.duration.seconds
        guard total > 0.5 else {
            throw TranscriptionError(message: "the clip would be empty")
        }
        let start = max(0, from - base)
        let length = min(total - start, to - from)
        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: max(0.5, length), preferredTimescale: 600))

        try? FileManager.default.removeItem(at: output)
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHEVC1920x1080] {
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            export.timeRange = timeRange
            do {
                try await export.export(to: output, as: .mp4)
                return output
            } catch {
                try? FileManager.default.removeItem(at: output)
                appLog("⚠️ Clip export (\(preset)) failed: \(error.localizedDescription)")
            }
        }
        throw TranscriptionError(message: "clip export failed")
    }

    /// Chiude tutto e cancella i segmenti temporanei.
    func shutdown() async {
        let waits: [Task<Void, Never>] = queue.sync {
            rotate(startingAt: nil)
            let list = finishing
            finishing.removeAll()
            return list
        }
        for task in waits { await task.value }
        try? FileManager.default.removeItem(at: dir)
    }
}
