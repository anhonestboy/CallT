import Foundation

/// Genera note organizzate (.md) da una trascrizione, con il modello
/// on-device di Apple Intelligence o con l'API Claude (se configurata).
protocol NotesEngine: Sendable {
    /// Riassume un testo (già dimensionato per il motore) secondo le istruzioni.
    func generate(instructions: String, prompt: String) async throws -> String
    /// Dimensione massima consigliata (in caratteri) del prompt per singola chiamata.
    var maxPromptChars: Int { get }
}

enum CallNotesGenerator {
    /// Costruisce la trascrizione con marcatori temporali [hh:mm:ss].
    static func timestampedText(from transcript: Transcript) -> String {
        transcript.segments.map { seg in
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = seg.start else { return body }
            let t = Int(start)
            let stamp = String(format: "[%02d:%02d:%02d]", t / 3600, (t % 3600) / 60, t % 60)
            return "\(stamp) \(body)"
        }.joined(separator: "\n")
    }

    static let noteInstructions = """
        You are an assistant that turns work-call transcripts into detailed, organized, \
        faithful notes. Always write the notes (including section headings) in the SAME \
        LANGUAGE as the transcript. Never invent information: when something is not in \
        the transcript, omit the corresponding section. Reply ONLY in Markdown.
        """

    static func finalPrompt(callName: String, material: String) -> String {
        """
        Turn the following material (transcript or partial notes of the call “\(callName)”) \
        into complete notes with this structure, translating the section headings into the \
        language of the material:

        # Notes — \(callName)
        ## Summary
        (4-6 sentences summarizing the call)
        ## Topics discussed
        (one ### subsection per topic, with the important details explained and, where \
        useful, the [hh:mm:ss] time references present in the material)
        ## Decisions
        ## Action items
        (list: what, who when identifiable, by when if mentioned)
        ## Open questions

        Omit sections that have no content. Here is the material:

        \(material)
        """
    }

    static func chunkPrompt(callName: String, part: Int, total: Int, chunk: String) -> String {
        """
        This is part \(part) of \(total) of the transcript of the call “\(callName)”. \
        Extract detailed bullet-point notes in the same language as the transcript: topics \
        discussed with the important details, decisions, action items, open questions. \
        Keep the [hh:mm:ss] time references. Do not add preambles or conclusions.

        \(chunk)
        """
    }

    /// Motore per un identificativo di impostazione, se configurato e pronto.
    static func engine(for id: String) -> (engine: NotesEngine, name: String)? {
        switch id {
        case "apple":
            return AppleNotesEngine.ifAvailable().map { ($0, "Apple") }
        case "claude":
            return ClaudeNotesEngine.fromSettings().map { ($0, "Claude \($0.model)") }
        default:
            guard let provider = OpenAICompatEngine.provider(id) else { return nil }
            return OpenAICompatEngine.fromSettings(providerID: id)
                .map { ($0, "\(provider.label) \($0.model)") }
        }
    }

    /// Motore attivo secondo le impostazioni; se il preferito non è pronto,
    /// ripiega sul modello Apple locale quando disponibile.
    static func activeEngine() -> (engine: NotesEngine, name: String)? {
        let preferred = AppSettings.notesEngine
        if let match = engine(for: preferred) { return match }
        if preferred != "apple", let apple = engine(for: "apple") {
            return (apple.engine, "Apple (ripiego)")
        }
        return nil
    }

    /// Genera il file di note. Lancia in caso di errore; il chiamante decide se è bloccante.
    static func generateNotes(
        transcript: Transcript, callName: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        guard let (engine, engineName) = activeEngine() else {
            throw TranscriptionError(message: "no notes engine available (enable Apple Intelligence or configure an API key in Settings → Notes)")
        }
        appLog("📝 Generating notes with the \(engineName) engine…")

        let text = timestampedText(from: transcript)
        if text.count <= engine.maxPromptChars {
            progress(0.3)
            let notes = try await engine.generate(
                instructions: noteInstructions,
                prompt: finalPrompt(callName: callName, material: text))
            progress(1.0)
            return notes
        }

        // Trascrizione più grande del contesto del motore: map → reduce.
        let chunks = split(text, maxChars: engine.maxPromptChars)
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let part = try await engine.generate(
                instructions: noteInstructions,
                prompt: chunkPrompt(callName: callName, part: index + 1, total: chunks.count, chunk: chunk))
            partials.append(part)
            progress(0.8 * Double(index + 1) / Double(chunks.count))
        }

        // Reduce hierarchically until the notes fit in a single call.
        var material = partials.joined(separator: "\n\n")
        while material.count > engine.maxPromptChars {
            let groups = split(material, maxChars: engine.maxPromptChars)
            var merged: [String] = []
            for group in groups {
                merged.append(try await engine.generate(
                    instructions: noteInstructions,
                    prompt: """
                    Merge and compact these partial notes of the call “\(callName)” into a \
                    single organized list, in the same language as the notes, without losing \
                    details, decisions or action items:

                    \(group)
                    """))
            }
            material = merged.joined(separator: "\n\n")
        }

        progress(0.9)
        let notes = try await engine.generate(
            instructions: noteInstructions,
            prompt: finalPrompt(callName: callName, material: material))
        progress(1.0)
        return notes
    }

    /// Divide il testo in blocchi ≤ maxChars rispettando i confini di riga.
    static func split(_ text: String, maxChars: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > maxChars, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
