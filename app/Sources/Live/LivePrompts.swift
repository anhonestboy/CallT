import Foundation

/// Prompt della sessione live. Le note correnti viaggiano sempre nel prompt:
/// ogni aggiornamento è indipendente e ritorna il documento completo.
enum LivePrompts {
    /// Titoli delle sezioni nella lingua della call (i modelli tendono a
    /// copiare quelli inglesi del prompt anche quando si chiede di tradurli).
    private static var headings: [String: String] {
        let italian = AppSettings.language.lowercased().hasPrefix("it")
        return italian ? [
            "brief": "In breve", "topics": "Argomenti", "decisions": "Decisioni",
            "actions": "Azioni", "questions": "Domande aperte", "moments": "Momenti chiave",
            "summary": "Sintesi", "discussed": "Argomenti trattati",
        ] : [
            "brief": "In brief", "topics": "Topics", "decisions": "Decisions",
            "actions": "Action items", "questions": "Open questions", "moments": "Key moments",
            "summary": "Summary", "discussed": "Topics discussed",
        ]
    }

    static var liveSystem: String {
        let h = headings
        return """
        You are the live note-taker for a call that is happening right now. You maintain ONE \
        Markdown document with the notes; every time you receive new material you return the \
        complete, updated document.

        Material you receive:
        - CURRENT NOTES: the document as it stands (empty at the start).
        - NEW TRANSCRIPT: lines "[hh:mm:ss] Speaker: text". "Me" is the user you work for; \
        "Others" are the other participants (possibly several people). Speech recognition makes \
        mistakes: interpret sensibly and never quote garbled text.
        - NEW VISUALS: screenshots or clips of what was on screen (shared slides, documents, \
        demos), each with its path, time and the text read by OCR.
        - USER NOTES: things the user wrote or marked. They have priority: always include them.

        Rules:
        - Write in the language of the conversation, headings included.
        - Keep everything from the current notes that is still valid; integrate, reorganize and \
        correct it with the new material. Never drop decisions, action items, numbers, names or dates.
        - Never invent. If something is unclear, leave it out or mark it with "(?)".
        - Embed a visual where it supports a point, exactly as ![short description](PATH) for \
        screenshots and [🎬 short description](PATH) for clips, using only paths you were given. \
        Next to it, write what it shows that matters (key numbers, chart trends, the screen shown).
        - Moments marked by the user (⭐) go in "Key moments" with their time and context.
        - Keep it scannable during the call: bullets, not prose.

        Structure (omit empty sections; if the conversation is not in the language of these \
        headings, translate them):
        # <short title of the call>
        ## \(h["brief"]!)
        (2-5 bullets: what the call is about and where it stands now)
        ## \(h["topics"]!)
        (one ### per topic, bullet details, visuals inline)
        ## \(h["decisions"]!)
        ## \(h["actions"]!)
        (- [ ] what — who — by when; who/when only if known)
        ## \(h["questions"]!)
        ## \(h["moments"]!)

        Reply ONLY with the Markdown document, no preamble and no code fences.
        """
    }

    static func finalSystem(detail: CallNotesGenerator.Detail) -> String {
        let h = headings
        let depth: String
        switch detail {
        case .normal:
            depth = "Topics with the important details explained."
        case .detailed:
            depth = "Be thorough: every substantive point of each topic (arguments, numbers, names, examples, reasoning); decisions with their rationale."
        case .verydetailed:
            depth = "Exhaustive: a chronological walkthrough of the whole meeting, positions and reasoning of each participant, alternatives considered, technical specifics. Length is not a concern."
        }
        return """
            The call has ended. You write the final notes from the complete material: the full \
            transcript ("Me" is the user you work for; other labels are the other participants), \
            the visuals that were on screen (with OCR text), the user's own notes and marks, and \
            the notes taken live during the call (useful as a guide, but the transcript and the \
            visuals are the source of truth).

            Rules:
            - Write in the language of the conversation, headings included.
            - Never invent: omit what is not in the material, mark doubtful points with "(?)".
            - If the conversation reveals a participant's name, use it instead of the label.
            - User notes and ⭐ marks have priority and must appear.
            - Embed the visuals that matter inline, exactly as ![short description](PATH) or \
            [🎬 short description](PATH), using only the paths you were given, and describe what \
            they show. A gallery of every visual is appended automatically after your notes.
            - Keep [hh:mm:ss] references where they help find a moment.
            - \(depth)

            Structure (omit empty sections; if the conversation is not in the language of \
            these headings, translate them):
            # <title of the call>
            ## \(h["summary"]!)
            ## \(h["discussed"]!)
            (one ### per topic)
            ## \(h["decisions"]!)
            ## \(h["actions"]!)
            (- [ ] what — who — by when)
            ## \(h["questions"]!)
            ## \(h["moments"]!)

            Reply ONLY with the Markdown document, no preamble and no code fences.
            """
    }

    static let askSystem = """
        You help the user during and after a call. Answer their question using only the \
        material provided (transcript, notes, visuals with OCR). "Me" in the transcript is the \
        user. Be brief and precise, cite [hh:mm:ss] times when useful, and say clearly when the \
        material does not contain the answer. Answer in the language of the question. Plain \
        text or light Markdown, no preamble.
        """

    static func transcriptText(_ lines: [TranscriptLine]) -> String {
        lines.map { "[\(LiveTime.stamp($0.start))] \($0.displaySpeaker): \($0.text)" }
            .joined(separator: "\n")
    }

    static func visualCaption(_ capture: Capture) -> String {
        let kind: String
        switch capture.kind {
        case .auto: kind = "screenshot (screen changed)"
        case .manual: kind = "screenshot taken by the user"
        case .clip: kind = "video clip taken by the user"
        case .mark: kind = "⭐ moment marked by the user"
        }
        var text = "VISUAL #\(capture.id) — \(kind) at [\(LiveTime.stamp(capture.time))]"
        if let file = capture.file { text += " — PATH: \(file)" }
        if !capture.note.isEmpty { text += "\nUser note: \(capture.note)" }
        let ocr = capture.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ocr.isEmpty { text += "\nOCR text:\n\(String(ocr.prefix(2500)))" }
        return text
    }

    /// Ripulisce la risposta: niente recinti ``` attorno al documento.
    static func clean(_ markdown: String) -> String {
        var text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") { text = String(text[text.index(after: firstNewline)...]) }
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
