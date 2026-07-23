import Foundation

/// Motore opzionale basato su whisper-cli (Homebrew) + modello ggml.
/// Disponibile solo se binario e modello esistono sul disco.
struct WhisperTranscriber: TranscriptionEngine {
    let binaryPath: String
    let modelPath: String

    static let candidateBinaries = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cpp",
    ]

    static func detectBinary() -> String? {
        candidateBinaries.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// nil se whisper non è utilizzabile su questa macchina.
    static func detect() -> WhisperTranscriber? {
        guard let bin = detectBinary() else { return nil }
        let model = AppSettings.whisperModelPath
        guard FileManager.default.fileExists(atPath: model) else { return nil }
        return WhisperTranscriber(binaryPath: bin, modelPath: model)
    }

    func transcribe(
        audioURL: URL,
        language: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        // whisper-cli vuole il sottotag primario ("it" da "it-IT", ma anche
        // codici a 3 lettere restano interi).
        let lang = language.split(separator: "-").first.map(String.init) ?? language
        // Output in una cartella temporanea: mai accanto al file dell'utente
        // (il percorso Intent può passare un file fuori dalle nostre cartelle).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("callt-whisper-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outBase = scratch.appendingPathComponent("out")

        let result = try await ProcessRunner.run(
            binaryPath,
            [
                "-m", modelPath,
                "-f", audioURL.path,
                "-l", lang,
                "-osrt", "-otxt",
                "-of", outBase.path,
                "-pp",  // stampa progresso su stderr
            ],
            timeout: 7200,
            onStderrLine: { line in
                // Righe tipo "whisper_print_progress_callback: progress =  10%"
                guard line.contains("progress") else { return }
                if let pct = line.split(separator: "=").last?
                    .trimmingCharacters(in: CharacterSet(charactersIn: " %\r")),
                   let value = Double(pct) {
                    progress(min(value / 100.0, 1.0))
                }
            })

        let txtURL = URL(fileURLWithPath: outBase.path + ".txt")
        let srtURL = URL(fileURLWithPath: outBase.path + ".srt")

        guard result.status == 0,
              let text = try? String(contentsOf: txtURL, encoding: .utf8)
        else {
            throw TranscriptionError(message: "whisper-cli failed: \(String(result.stderr.suffix(400)))")
        }

        if let srt = try? String(contentsOf: srtURL, encoding: .utf8) {
            return Transcript(segments: Self.parseSRT(srt, fallbackText: text))
        }
        return Transcript(segments: [.init(start: nil, end: nil, text: text)])
    }

    /// Converte l'SRT di whisper in segmenti per avere tempi uniformi tra i motori.
    static func parseSRT(_ srt: String, fallbackText: String) -> [Transcript.Segment] {
        var segments: [Transcript.Segment] = []
        let blocks = srt.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n").map(String.init)
            guard lines.count >= 3, lines[1].contains("-->") else { continue }
            let times = lines[1].components(separatedBy: " --> ")
            guard times.count == 2,
                  let start = parseSRTTime(times[0]),
                  let end = parseSRTTime(times[1])
            else { continue }
            segments.append(.init(start: start, end: end, text: lines[2...].joined(separator: " ")))
        }
        if segments.isEmpty {
            segments = [.init(start: nil, end: nil, text: fallbackText)]
        }
        return segments
    }

    static func parseSRTTime(_ s: String) -> TimeInterval? {
        // "00:01:02,345"
        let cleaned = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2])
        else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
