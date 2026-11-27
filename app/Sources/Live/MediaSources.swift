import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Callback dei flussi media di una sessione. Tutti i buffer portano PTS sul
/// clock host (cattura reale) o sul tempo del file (simulazione); `origin` della
/// sorgente è l'istante zero della sessione su quello stesso clock.
struct MediaHandlers: Sendable {
    var systemAudio: @Sendable (CMSampleBuffer) -> Void = { _ in }
    var micAudio: @Sendable (CMSampleBuffer) -> Void = { _ in }
    var video: @Sendable (CMSampleBuffer) -> Void = { _ in }
    var stopped: @Sendable (Error?) -> Void = { _ in }
}

protocol LiveMediaSource: AnyObject, Sendable {
    var origin: CMTime { get }
    var producesVideo: Bool { get }
    var videoSize: CGSize { get }
    var targetDescription: String { get }
    func start() async throws
    func stop() async
}

// MARK: - Cattura reale (ScreenCaptureKit + microfono via AVCapture)

/// Audio di sistema e (opzionale) video da ScreenCaptureKit; microfono SEMPRE
/// da AVCapture su un percorso separato (vedi MicCapture): SCK si
/// impossesserebbe del dispositivo e romperebbe l'echo cancellation della call.
final class ScreenCaptureSource: NSObject, LiveMediaSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private(set) var origin: CMTime = .zero
    let producesVideo: Bool
    let videoSize: CGSize
    let targetDescription: String

    private let target: ResolvedCaptureTarget
    private let wantsMic: Bool
    private let fps: Int
    private let handlers: MediaHandlers
    private let videoQueue = DispatchQueue(label: "com.werootbox.callt.live.video")
    private let audioQueue = DispatchQueue(label: "com.werootbox.callt.live.audio")
    private var stream: SCStream?
    private var mic: MicCapture?
    private var repeatTimer: DispatchSourceTimer?
    private var lastFrame: CMSampleBuffer?
    private var lastEmit: Double = 0
    private var micOffset: CMTime?

    init(target: ResolvedCaptureTarget, wantsVideo: Bool, wantsMic: Bool, fps: Int, handlers: MediaHandlers) {
        self.target = target
        self.producesVideo = wantsVideo
        self.videoSize = wantsVideo ? target.pixelSize : .zero
        self.targetDescription = target.description
        self.wantsMic = wantsMic
        self.fps = fps
        self.handlers = handlers
    }

    func start() async throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = false
        config.sampleRate = 48_000
        config.channelCount = 2
        config.queueDepth = 6
        if producesVideo {
            config.width = Int(videoSize.width)
            config.height = Int(videoSize.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.showsCursor = true
            config.scalesToFit = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
        } else {
            config.width = 64
            config.height = 64
            config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        }

        let stream = SCStream(filter: target.filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        if producesVideo {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        }
        origin = CMClockGetTime(CMClockGetHostTimeClock())
        try await stream.startCapture()
        self.stream = stream

        if wantsMic {
            let mic = MicCapture()
            let handlers = self.handlers
            if mic.start(onBuffer: { [weak self] buffer in
                guard let self, let retimed = self.retimeMic(buffer) else { return }
                handlers.micAudio(retimed)
            }) {
                self.mic = mic
            }
        }
        if producesVideo { startRepeatTimer() }
    }

    func stop() async {
        repeatTimer?.cancel()
        repeatTimer = nil
        mic?.stop()
        mic = nil
        try? await stream?.stopCapture()
        stream = nil
        videoQueue.sync { lastFrame = nil }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .audio:
            handlers.systemAudio(sampleBuffer)
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            lastFrame = sampleBuffer
            lastEmit = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            handlers.video(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        appLog("⚠️ Capture stopped: \(error.localizedDescription)")
        handlers.stopped(error)
    }

    private static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete && CMSampleBufferGetImageBuffer(buffer) != nil
    }

    /// SCK consegna frame solo quando lo schermo cambia: con una slide ferma per
    /// minuti non arriverebbe nulla. Ripete l'ultimo frame ogni secondo, così
    /// clip e registrazione restano continue.
    private func startRepeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, let last = self.lastFrame else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            guard now.seconds - self.lastEmit >= 1.0 else { return }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: last,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &copy) == noErr, let copy else { return }
            self.lastEmit = now.seconds
            self.handlers.video(copy)
        }
        timer.resume()
        repeatTimer = timer
    }

    /// Porta i buffer del microfono sul clock host se AVCapture usa un clock
    /// diverso (scarto > 1 s), così si allineano all'audio di sistema.
    private func retimeMic(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid else { return nil }
        if micOffset == nil {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let delta = CMTimeSubtract(now, pts)
            micOffset = abs(delta.seconds) > 1 ? delta : .zero
        }
        guard let offset = micOffset, offset != .zero else { return buffer }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer),
            presentationTimeStamp: CMTimeAdd(pts, offset),
            decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &copy) == noErr else { return nil }
        return copy
    }
}

// MARK: - Simulazione da file

/// Rilegge una registrazione esistente come se fosse una call in corso, a
/// velocità reale o accelerata. La prima traccia audio fa da "altri", la
/// seconda (se c'è, come nelle registrazioni di CallT) da "io".
/// Serve a collaudare la modalità live senza essere in call.
final class FileReplaySource: LiveMediaSource, @unchecked Sendable {
    let origin: CMTime = .zero
    private(set) var producesVideo = false
    private(set) var videoSize: CGSize = .zero
    var targetDescription: String { String(localized: "Replay: \(url.lastPathComponent)") }

    private let url: URL
    private let speed: Double
    private let handlers: MediaHandlers
    private var tasks: [Task<Void, Never>] = []
    private var wallStart = Date()

    init(url: URL, speed: Double, handlers: MediaHandlers) {
        self.url = url
        self.speed = max(0.1, speed)
        self.handlers = handlers
    }

    func start() async throws {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let video = videoTracks.first {
            let size = try await video.load(.naturalSize)
            let scale = min(1, 2560 / max(size.width, size.height))
            videoSize = CGSize(width: CGFloat(Int(size.width * scale) & ~1),
                               height: CGFloat(Int(size.height * scale) & ~1))
            producesVideo = true
        }
        wallStart = Date()
        let handlers = self.handlers
        if let video = videoTracks.first {
            let size = videoSize
            tasks.append(pump(asset: asset, track: video, settings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ], deliver: handlers.video))
        }
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        for (index, track) in audioTracks.prefix(2).enumerated() {
            tasks.append(pump(asset: asset, track: track, settings: pcm,
                              deliver: index == 0 ? handlers.systemAudio : handlers.micAudio))
        }
        let all = tasks
        Task.detached {
            for task in all { await task.value }
            handlers.stopped(nil)
        }
    }

    func stop() async {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    private func pump(
        asset: AVURLAsset, track: AVAssetTrack, settings: [String: Any],
        deliver: @escaping @Sendable (CMSampleBuffer) -> Void
    ) -> Task<Void, Never> {
        nonisolated(unsafe) let asset = asset
        nonisolated(unsafe) let track = track
        nonisolated(unsafe) let settings = settings
        let speed = self.speed
        let wallStart = self.wallStart
        return Task.detached(priority: .userInitiated) {
            guard let reader = try? AVAssetReader(asset: asset) else { return }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return }
            reader.add(output)
            guard reader.startReading() else { return }
            while !Task.isCancelled, let buffer = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                let due = pts / speed - Date().timeIntervalSince(wallStart)
                if due > 0.005 {
                    try? await Task.sleep(nanoseconds: UInt64(due * 1_000_000_000))
                }
                deliver(buffer)
            }
            reader.cancelReading()
        }
    }
}
