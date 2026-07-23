import Foundation

/// Risultato di una trascrizione, con segmenti temporizzati quando disponibili.
struct Transcript: Sendable {
    struct Segment: Sendable {
        var start: TimeInterval?
        var end: TimeInterval?
        var text: String
    }

    var segments: [Segment]
    /// Parole/run temporizzati a grana fine (se il motore li fornisce):
    /// usati per sottotitoli di dimensione naturale invece di blocchi enormi.
    var fineSegments: [Segment] = []

    var text: String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Genera un file SRT dai segmenti temporizzati (quelli senza tempi vengono saltati).
    func srt() -> String {
        let source = fineSegments.isEmpty ? segments : Self.chunk(fineSegments)
        var out = ""
        var index = 1
        for seg in source {
            guard let start = seg.start, let end = seg.end else { continue }
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            out += "\(index)\n\(Self.srtTime(start)) --> \(Self.srtTime(end))\n\(body)\n\n"
            index += 1
        }
        return out
    }

    /// Raggruppa parole temporizzate in blocchi da sottotitolo (max ~5,5s / ~84 caratteri).
    static func chunk(
        _ words: [Segment], maxDuration: TimeInterval = 5.5, maxChars: Int = 84
    ) -> [Segment] {
        var out: [Segment] = []
        var current: Segment?
        for word in words {
            guard let ws = word.start, let we = word.end else {
                current?.text += word.text
                continue
            }
            if var block = current, let bs = block.start,
               we - bs <= maxDuration, block.text.count + word.text.count <= maxChars {
                block.text += word.text
                block.end = we
                current = block
            } else {
                if let block = current { out.append(block) }
                current = Segment(start: ws, end: we, text: word.text)
            }
        }
        if let block = current { out.append(block) }
        return out
    }

    static func srtTime(_ t: TimeInterval) -> String {
        let ms = Int((t.truncatingRemainder(dividingBy: 1)) * 1000)
        let total = Int(t)
        return String(format: "%02d:%02d:%02d,%03d", total / 3600, (total % 3600) / 60, total % 60, ms)
    }
}

protocol TranscriptionEngine: Sendable {
    /// Trascrive un file audio (WAV/M4A). `progress` riceve valori 0…1.
    func transcribe(
        audioURL: URL,
        language: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript
}

struct TranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
