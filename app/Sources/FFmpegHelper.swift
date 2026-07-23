import Foundation

/// Percorso opzionale per i file .mkv, che AVFoundation non sa leggere.
/// Usato solo se ffmpeg è installato (Homebrew o /usr/local).
enum FFmpegHelper {
    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var ffprobePath: String? {
        ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var available: Bool { ffmpegPath != nil && ffprobePath != nil }

    struct Probe {
        var duration: Double
        var width: Int
        var height: Int
        var fps: Double
        var videoBitrate: Double  // bit/s, stimato dal totale se mancante
        var hasAudio: Bool
    }

    static func probe(_ url: URL) async throws -> Probe {
        guard let ffprobe = ffprobePath else {
            throw TranscriptionError(message: "ffprobe not found")
        }
        let json = try await runProcess(ffprobe, [
            "-v", "quiet", "-print_format", "json",
            "-show_format", "-show_streams", url.path,
        ])
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = obj["streams"] as? [[String: Any]],
              let format = obj["format"] as? [String: Any],
              let video = streams.first(where: { $0["codec_type"] as? String == "video" })
        else {
            throw TranscriptionError(message: "ffprobe: invalid output")
        }
        let duration = Double(format["duration"] as? String ?? "") ?? 0
        let width = video["width"] as? Int ?? 0
        let height = video["height"] as? Int ?? 0
        var fps = 30.0
        if let rate = video["avg_frame_rate"] as? String {
            let parts = rate.split(separator: "/")
            if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 {
                fps = n / d
            }
        }
        var videoBitrate = Double(video["bit_rate"] as? String ?? "") ?? 0
        if videoBitrate == 0 {
            // MKV spesso non riporta il bitrate per stream: stima dal totale meno l'audio.
            let total = Double(format["bit_rate"] as? String ?? "") ?? 0
            videoBitrate = max(total - 128_000, total * 0.85)
        }
        guard duration > 0, width > 0, height > 0 else {
            throw TranscriptionError(message: "ffprobe: incomplete metadata")
        }
        let hasAudio = streams.contains { $0["codec_type"] as? String == "audio" }
        return Probe(duration: duration, width: width, height: height, fps: fps,
                     videoBitrate: videoBitrate, hasAudio: hasAudio)
    }

    static func extractWAV(from video: URL, to wav: URL) async throws {
        guard let ffmpeg = ffmpegPath else {
            throw TranscriptionError(message: "ffmpeg not found")
        }
        _ = try await runProcess(ffmpeg, [
            "-y", "-i", video.path,
            "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
            wav.path,
        ], timeout: 1800)
    }

    static func compress(
        source: URL, destination: URL,
        quality: CompressionQuality, downscale: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VideoCompressor.Result {
        guard let ffmpeg = ffmpegPath else {
            throw TranscriptionError(message: "ffmpeg not found")
        }
        let info = try await probe(source)
        guard let target = VideoCompressor.targetBitrate(
            width: info.width, height: info.height, fps: info.fps,
            sourceBitrate: info.videoBitrate, quality: quality, downscale: downscale)
        else {
            return .skippedAlreadyEfficient
        }

        var args = ["-y", "-i", source.path]
        // Scala calcolata in Swift (gestisce anche i video verticali,
        // stessa formula usata per il bitrate target).
        let w = Double(info.width), h = Double(info.height)
        let scale = min(1.0, 1920.0 / max(w, h), 1080.0 / min(w, h))
        if downscale, scale < 1.0 {
            let outW = Int(w * scale) & ~1
            let outH = Int(h * scale) & ~1
            args += ["-vf", "scale=\(outW):\(outH)"]
        }
        args += [
            "-c:v", "hevc_videotoolbox", "-b:v", "\(Int(target))",
            "-tag:v", "hvc1",
            "-c:a", "aac", "-b:a", "96k",
            "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            destination.path,
        ]

        let duration = info.duration
        do {
            _ = try await runProcess(ffmpeg, args, timeout: 7200) { line in
                if line.hasPrefix("out_time_ms="), let us = Double(line.dropFirst("out_time_ms=".count)) {
                    progress(min(us / 1_000_000 / duration, 1.0))
                }
            }
        } catch {
            // Non lasciare un file parziale nella cartella di output.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return VideoCompressor.sizeGuard(source: source, destination: destination)
    }

    @discardableResult
    private static func runProcess(
        _ path: String, _ arguments: [String], timeout: TimeInterval = 120,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let result = try await ProcessRunner.run(path, arguments, timeout: timeout, onStdoutLine: onStdoutLine)
        guard result.status == 0 else {
            let tail = String(result.stderr.suffix(400))
            throw TranscriptionError(message: "\(URL(fileURLWithPath: path).lastPathComponent): \(tail)")
        }
        return result.stdout
    }
}
