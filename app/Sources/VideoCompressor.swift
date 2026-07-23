import Foundation
import AVFoundation
import VideoToolbox

/// Compressione HEVC hardware con bitrate calcolato dal sorgente.
/// Garanzia: il file compresso non è mai più pesante dell'originale —
/// se non conviene, la compressione viene saltata o il risultato scartato.
enum VideoCompressor {
    enum Result: Sendable {
        case compressed(saved: Int)       // percentuale risparmiata
        case skippedAlreadyEfficient      // il sorgente è già ben compresso
        case skippedNotSmaller            // il risultato non era più piccolo
    }

    /// Bitrate target in bit/s, o nil se comprimere non conviene.
    /// - target ideale = bit-per-pixel·frame della qualità scelta
    /// - mai sopra il 65% del bitrate sorgente (HEVC ≈ stessa qualità di H.264 a ~0,65×)
    /// - sotto la soglia di qualità minima non si comprime affatto
    static func targetBitrate(
        width: Int, height: Int, fps: Double,
        sourceBitrate: Double, quality: CompressionQuality, downscale: Bool
    ) -> Double? {
        var w = Double(width), h = Double(height)
        if downscale {
            let scale = min(1.0, 1920.0 / max(w, h), 1080.0 / min(w, h))
            w *= scale
            h *= scale
        }
        let effFPS = fps > 1 ? min(fps, 60) : 30
        let ideal = quality.bitsPerPixel * w * h * effFPS
        guard sourceBitrate > 0 else { return max(ideal, 250_000) }

        let target = min(ideal, sourceBitrate * 0.65)
        let qualityFloor = max(0.015 * w * h * effFPS, 250_000)
        guard target >= qualityFloor else { return nil }
        return target
    }

    /// Controllo finale: mantiene il compresso solo se almeno il 5% più piccolo.
    static func sizeGuard(source: URL, destination: URL) -> Result {
        let fm = FileManager.default
        let srcSize = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int64).flatMap { $0 } ?? 0
        let dstSize = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64).flatMap { $0 } ?? 0
        guard srcSize > 0, dstSize > 0, Double(dstSize) < Double(srcSize) * 0.95 else {
            try? fm.removeItem(at: destination)
            return .skippedNotSmaller
        }
        return .compressed(saved: Int((1.0 - Double(dstSize) / Double(srcSize)) * 100))
    }

    static func compress(
        source: URL, destination: URL,
        quality: CompressionQuality, downscale: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {
        let asset = AVURLAsset(url: source)
        let (tracks, duration) = try await asset.load(.tracks, .duration)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        guard let vTrack = videoTracks.first else {
            throw TranscriptionError(message: "no video track")
        }
        let (naturalSize, transform, fps, dataRate) = try await vTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)

        guard let target = targetBitrate(
            width: Int(naturalSize.width), height: Int(naturalSize.height),
            fps: Double(fps), sourceBitrate: Double(dataRate),
            quality: quality, downscale: downscale)
        else {
            return .skippedAlreadyEfficient
        }

        // Dimensioni di uscita rispettando la rotazione (preferredTransform).
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        let scale: CGFloat = downscale
            ? min(1.0, 1920.0 / max(displaySize.width, displaySize.height),
                  1080.0 / min(displaySize.width, displaySize.height))
            : 1.0
        func evenFloor(_ x: CGFloat) -> Int { Int(x.rounded(.down)) & ~1 }
        let outSize = CGSize(
            width: CGFloat(evenFloor(displaySize.width * scale)),
            height: CGFloat(evenFloor(displaySize.height * scale)))
        let effFPS = fps > 1 ? min(fps, 60) : 30

        // Composizione: ruota e scala in un'unica trasformazione.
        let toOrigin = CGAffineTransform(
            translationX: -min(displayRect.minX, displayRect.maxX),
            y: -min(displayRect.minY, displayRect.maxY))
        let fullTransform = transform.concatenating(toOrigin)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        var layerConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: vTrack)
        layerConfig.setTransform(fullTransform, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layerConfig)],
            timeRange: CMTimeRange(start: .zero, duration: duration)))
        let composition = AVVideoComposition(configuration: .init(
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(max(1, effFPS.rounded()))),
            instructions: [instruction],
            renderSize: outSize))

        try? FileManager.default.removeItem(at: destination)

        // Due reader SEPARATI (video e audio): con un reader solo, sorgenti con
        // interleaving a blocchi larghi mandano in stallo il triangolo
        // reader ↔ writer (il writer aspetta video, il reader ha il buffer
        // audio pieno, l'audio non viene accettato finché non arriva video).
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false

        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioChannels = 2
        if !audioTracks.isEmpty {
            if let desc = try? await audioTracks[0].load(.formatDescriptions).first,
               let asbd = desc.audioStreamBasicDescription {
                audioChannels = min(2, max(1, Int(asbd.mChannelsPerFrame)))
            }
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: audioChannels,
            ])
            out.alwaysCopiesSampleData = false
            audioOutput = out
            audioReader = try AVAssetReader(asset: asset)
        }

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(outSize.width),
            AVVideoHeightKey: Int(outSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(target),
                AVVideoExpectedSourceFrameRateKey: Int(max(1, effFPS.rounded())),
                AVVideoMaxKeyFrameIntervalKey: Int(max(1, effFPS.rounded())) * 2,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: audioChannels,
                AVEncoderBitRateKey: audioChannels == 1 ? 64_000 : 96_000,
            ])
            input.expectsMediaDataInRealTime = false
            audioInput = input
        }

        // Pump con l'API classica (requestMediaDataWhenReady + copyNextSampleBuffer):
        // la nuova API async provider/receiver di macOS 26 si è dimostrata
        // inaffidabile su file lunghi (stallo dopo ~1 minuto su video di 2 ore),
        // mentre questo pattern è collaudato da 15 anni di produzione.
        guard reader.canAdd(videoOutput) else {
            throw TranscriptionError(message: "cannot add the video output")
        }
        reader.add(videoOutput)
        if let audioReader, let audioOutput {
            guard audioReader.canAdd(audioOutput) else {
                throw TranscriptionError(message: "cannot add the audio output")
            }
            audioReader.add(audioOutput)
        }
        guard writer.canAdd(videoInput) else {
            throw TranscriptionError(message: "cannot add the video input")
        }
        writer.add(videoInput)
        if let audioInput {
            guard writer.canAdd(audioInput) else {
                throw TranscriptionError(message: "cannot add the audio input")
            }
            writer.add(audioInput)
        }

        guard reader.startReading() else {
            throw reader.error ?? TranscriptionError(message: "reading video failed")
        }
        if let audioReader {
            guard audioReader.startReading() else {
                reader.cancelReading()
                throw audioReader.error ?? TranscriptionError(message: "reading audio failed")
            }
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            audioReader?.cancelReading()
            throw writer.error ?? TranscriptionError(message: "writing video failed")
        }
        writer.startSession(atSourceTime: .zero)

        final class LaneState: @unchecked Sendable {
            var finished = false
            var lastPercent = -1
        }

        let durationSeconds = duration.seconds
        nonisolated(unsafe) let vOut = videoOutput
        nonisolated(unsafe) let vIn = videoInput
        nonisolated(unsafe) let aOut = audioOutput
        nonisolated(unsafe) let aIn = audioInput

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            let videoQueue = DispatchQueue(label: "com.werootbox.callt.pump.video")
            let audioQueue = DispatchQueue(label: "com.werootbox.callt.pump.audio")

            let videoState = LaneState()
            group.enter()
            vIn.requestMediaDataWhenReady(on: videoQueue) {
                while vIn.isReadyForMoreMediaData {
                    guard let sample = vOut.copyNextSampleBuffer() else {
                        if !videoState.finished {
                            videoState.finished = true
                            vIn.markAsFinished()
                            group.leave()
                        }
                        return
                    }
                    guard vIn.append(sample) else {
                        // Il writer è in errore: chiudi la lane, lo stato
                        // viene controllato a valle.
                        if !videoState.finished {
                            videoState.finished = true
                            vIn.markAsFinished()
                            group.leave()
                        }
                        return
                    }
                    if durationSeconds > 0 {
                        let fraction = min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / durationSeconds)
                        let percent = Int(fraction * 100)
                        if percent != videoState.lastPercent {
                            videoState.lastPercent = percent
                            progress(fraction)
                        }
                    }
                }
            }

            if let aOut, let aIn {
                let audioState = LaneState()
                group.enter()
                aIn.requestMediaDataWhenReady(on: audioQueue) {
                    while aIn.isReadyForMoreMediaData {
                        guard let sample = aOut.copyNextSampleBuffer(), aIn.append(sample) else {
                            if !audioState.finished {
                                audioState.finished = true
                                aIn.markAsFinished()
                                group.leave()
                            }
                            return
                        }
                    }
                }
            }

            group.notify(queue: .global()) { cont.resume() }
        }

        if reader.status == .failed || audioReader?.status == .failed || writer.status == .failed {
            let error = reader.error ?? audioReader?.error ?? writer.error
            reader.cancelReading()
            audioReader?.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error ?? TranscriptionError(message: "transcode failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw writer.error ?? TranscriptionError(message: "writing video failed")
        }

        return sizeGuard(source: source, destination: destination)
    }
}
