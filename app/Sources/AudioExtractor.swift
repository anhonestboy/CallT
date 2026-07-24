import Foundation
import AVFoundation

/// Estrazione audio da video con AVFoundation (nessuna dipendenza esterna).
enum AudioExtractor {
    /// Esporta la traccia audio in M4A (AAC) — veloce, adatto al motore Apple.
    static func exportM4A(from video: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: video)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else {
            throw TranscriptionError(message: "the file has no audio tracks")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError(message: "the file has no exportable audio")
        }
        try? FileManager.default.removeItem(at: destination)
        try await session.export(to: destination, as: .m4a)
    }

    /// Estrae WAV 16 kHz mono 16-bit (per whisper-cli o per l'archiviazione).
    static func extractWAV(from video: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw TranscriptionError(message: "the file has no audio tracks")
        }
        try? FileManager.default.removeItem(at: destination)

        let pcm16k: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Classic single-lane pump (requestMediaDataWhenReady + copyNextSampleBuffer):
        // the macOS 26 async provider/receiver API fails with OSStatus -50 on
        // some AAC layouts (e.g. Teams recordings) and stalls on long files.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm16k)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TranscriptionError(message: "cannot add the audio output")
        }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm16k)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw TranscriptionError(message: "cannot add the audio input")
        }
        writer.add(input)

        guard reader.startReading() else {
            throw reader.error ?? TranscriptionError(message: "reading audio failed")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? TranscriptionError(message: "writing the WAV failed")
        }
        writer.startSession(atSourceTime: .zero)

        final class LaneState: @unchecked Sendable { var finished = false }
        nonisolated(unsafe) let out = output
        nonisolated(unsafe) let inp = input
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.werootbox.callt.wav")
            let state = LaneState()
            inp.requestMediaDataWhenReady(on: queue) {
                while inp.isReadyForMoreMediaData {
                    guard let sample = out.copyNextSampleBuffer(), inp.append(sample) else {
                        if !state.finished {
                            state.finished = true
                            inp.markAsFinished()
                            cont.resume()
                        }
                        return
                    }
                }
            }
        }
        await writer.finishWriting()
        if reader.status == .failed {
            try? FileManager.default.removeItem(at: destination)
            throw reader.error ?? TranscriptionError(message: "reading audio failed")
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw writer.error ?? TranscriptionError(message: "writing the WAV failed")
        }
    }
}
