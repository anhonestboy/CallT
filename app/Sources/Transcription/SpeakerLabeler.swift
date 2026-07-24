import Foundation

/// Diarizzazione: esegue il helper bundled (FluidAudio/CoreML) e fonde i
/// turni di parola con la trascrizione, producendo segmenti "Speaker N: …".
enum SpeakerLabeler {
    struct DiarSegment: Sendable {
        let speaker: String
        let start: Double
        let end: Double
    }

    static var helperURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("callt-diarizer")
    }

    static var available: Bool {
        helperURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
    }

    /// Esegue la diarizzazione su un WAV 16k mono. I modelli (~100MB) vengono
    /// scaricati automaticamente alla prima esecuzione.
    static func diarize(wav: URL) async throws -> [DiarSegment] {
        guard let helper = helperURL else {
            throw TranscriptionError(message: "diarizer helper missing from the bundle")
        }
        let result = try await ProcessRunner.run(helper.path, [wav.path], timeout: 3600)
        guard result.status == 0 else {
            throw TranscriptionError(message: "diarizer: \(String(result.stderr.suffix(300)))")
        }
        guard let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["segments"] as? [[String: Any]]
        else {
            throw TranscriptionError(message: "diarizer: invalid output")
        }
        return raw.compactMap { item in
            guard let speaker = item["speaker"] as? String,
                  let start = item["start"] as? Double,
                  let end = item["end"] as? Double else { return nil }
            return DiarSegment(speaker: speaker, start: start, end: end)
        }.sorted { $0.start < $1.start }
    }

    /// Etichetta leggibile: "S1" → "Speaker 1".
    static func label(_ speakerID: String) -> String {
        let digits = speakerID.drop(while: { !$0.isNumber })
        return digits.isEmpty ? "Speaker \(speakerID)" : "Speaker \(digits)"
    }

    /// Fonde i turni di parola con la trascrizione: ricostruisce i segmenti
    /// raggruppando il testo per parlante, con prefisso "Speaker N:".
    static func apply(_ diar: [DiarSegment], to transcript: Transcript) -> Transcript {
        guard !diar.isEmpty else { return transcript }
        let fine = !transcript.fineSegments.isEmpty
        let units = fine ? transcript.fineSegments : transcript.segments
        guard !units.isEmpty else { return transcript }

        func containing(_ time: Double) -> String? {
            diar.first { time >= $0.start && time <= $0.end }?.speaker
        }
        func nearest(_ time: Double) -> String {
            diar.min {
                min(abs($0.start - time), abs($0.end - time))
                    < min(abs($1.start - time), abs($1.end - time))
            }?.speaker ?? diar[0].speaker
        }

        var out: [Transcript.Segment] = []
        var currentSpeaker: String?
        var currentSegment: Transcript.Segment?

        for unit in units {
            let start = unit.start ?? currentSegment?.end ?? 0
            let end = unit.end ?? start
            let mid = (start + end) / 2
            // Nei silenzi tra i turni resta "attaccato" all'ultimo parlante.
            let speaker = containing(mid) ?? currentSpeaker ?? nearest(mid)

            if speaker == currentSpeaker, var segment = currentSegment {
                segment.text += fine ? unit.text : " " + unit.text.trimmingCharacters(in: .whitespacesAndNewlines)
                segment.end = unit.end ?? segment.end
                currentSegment = segment
            } else {
                if let segment = currentSegment { out.append(segment) }
                currentSpeaker = speaker
                currentSegment = Transcript.Segment(
                    start: unit.start, end: unit.end,
                    text: "\(label(speaker)): " + unit.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let segment = currentSegment { out.append(segment) }

        // I fine segments restano senza etichette (servono all'SRT parola-per-parola).
        return Transcript(segments: out, fineSegments: transcript.fineSegments)
    }
}
