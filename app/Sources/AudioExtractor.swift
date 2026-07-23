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
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm16k)
        output.alwaysCopiesSampleData = false
        let writer = try AVAssetWriter(outputURL: destination, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm16k)
        input.expectsMediaDataInRealTime = false

        // I provider/receiver vanno creati PRIMA di startReading()/start().
        let provider = reader.outputProvider(for: output)
        let receiver = writer.inputReceiver(for: input)

        guard reader.startReading() else {
            throw reader.error ?? TranscriptionError(message: "reading audio failed")
        }
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        while let sample = try await provider.next() {
            try await receiver.append(sample)
        }
        receiver.finish()
        await writer.finishWriting()
        if reader.status == .failed {
            throw reader.error ?? TranscriptionError(message: "reading audio failed")
        }
        guard writer.status == .completed else {
            throw writer.error ?? TranscriptionError(message: "writing the WAV failed")
        }
    }
}
