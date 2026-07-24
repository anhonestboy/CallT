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

    enum Detail: String {
        case normal, detailed, verydetailed

        static var current: Detail {
            Detail(rawValue: AppSettings.notesDetail) ?? .normal
        }
    }

    static let noteInstructions = """
        You are an assistant that turns work-call transcripts into detailed, organized, \
        faithful notes. Always write the notes (including section headings) in the SAME \
        LANGUAGE as the transcript. Never invent information: when something is not in \
        the transcript, omit the corresponding section. When the transcript carries \
        "Speaker N:" labels, attribute positions and statements to the speakers; if the \
        conversation reveals a speaker's real name, use the name instead of the label, \
        consistently. Reply ONLY in Markdown.
        """

    private static var timestampRule: String {
        AppSettings.notesTimestamps
            ? "Where useful, keep the [hh:mm:ss] time references present in the material."
            : "Do NOT include time references like [hh:mm:ss] in the notes."
    }

    static func finalPrompt(callName: String, material: String) -> String {
        let structure: String
        switch Detail.current {
        case .normal:
            structure = """
            # Notes — \(callName)
            ## Summary
            (4-6 sentences summarizing the call)
            ## Topics discussed
            (one ### subsection per topic, with the important details explained)
            ## Decisions
            ## Action items
            (list: what, who when identifiable, by when if mentioned)
            ## Open questions
            """
        case .detailed:
            structure = """
            # Notes — \(callName)
            ## Summary
            (6-10 sentences summarizing the call)
            ## Topics discussed
            (one ### subsection per topic. Be thorough: capture every substantive point — \
            arguments, numbers, names, examples, context and reasoning. Do not condense \
            distinct points together; prefer completeness over brevity)
            ## Decisions
            (each decision with its rationale)
            ## Action items
            (list: what, who when identifiable, by when if mentioned)
            ## Open questions
            """
        case .verydetailed:
            structure = """
            # Notes — \(callName)
            ## Summary
            (8-12 sentences summarizing the call)
            ## Meeting walkthrough
            (an in-depth chronological account: one ### subsection per phase of the \
            discussion, in order. For each, explain in full what was discussed and why: \
            positions taken and by whom when identifiable, reasoning, alternatives \
            considered, technical specifics, numbers, names and examples. Length is not \
            a concern — exhaustive coverage is the goal)
            ## Decisions
            (each decision with its rationale and any conditions)
            ## Action items
            (list: what, who when identifiable, by when if mentioned)
            ## Open questions
            """
        }
        return """
        Turn the following material (transcript or partial notes of the call “\(callName)”) \
        into complete notes with this structure, translating the section headings into the \
        language of the material. \(timestampRule)

        \(structure)

        Omit sections that have no content. Here is the material:

        \(material)
        """
    }

    static func chunkPrompt(callName: String, part: Int, total: Int, chunk: String) -> String {
        let depth: String
        switch Detail.current {
        case .normal:
            depth = "topics discussed with the important details, decisions, action items, open questions"
        case .detailed:
            depth = "every substantive point of each topic (arguments, numbers, names, examples, reasoning), decisions with their rationale, action items, open questions"
        case .verydetailed:
            depth = "a full chronological account of everything discussed (positions, reasoning, alternatives, technical specifics, numbers, names, examples), decisions with rationale, action items, open questions — exhaustive coverage, length is not a concern"
        }
        return """
        This is part \(part) of \(total) of the transcript of the call “\(callName)”. \
        Extract detailed bullet-point notes in the same language as the transcript: \(depth). \
        \(timestampRule) Do not add preambles or conclusions.

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
