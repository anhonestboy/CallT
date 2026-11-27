import Foundation

/// Motore note via API Claude (Anthropic) — HTTP diretto con streaming SSE.
/// La qualità migliore per note lunghe e dettagliate; richiede una chiave API.
struct ClaudeNotesEngine: NotesEngine {
    let apiKey: String
    let model: String
    // Contesto ampio (1M token sui modelli attuali): una trascrizione di 2 ore
    // entra in una singola chiamata.
    let maxPromptChars = 500_000

    static let keychainAccount = "apikey-claude"
    static var models: [(String, String)] {
        [
            ("claude-opus-5-5", String(localized: "Claude Opus 5.5 (best)")),
            ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
            ("claude-haiku-5-5", String(localized: "Claude Haiku 5.5 (budget)")),
        ]
    }

    static func fromSettings() -> ClaudeNotesEngine? {
        guard let key = KeychainStore.read(keychainAccount), !key.isEmpty else { return nil }
        return ClaudeNotesEngine(apiKey: key, model: AppSettings.notesModel(for: "claude"))
    }

    func generate(instructions: String, prompt: String) async throws -> String {
        var headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        var extra: [String: Any] = [:]
        // Ripiego lato server se un classificatore rifiuta (non disponibile su Haiku).
        if !model.contains("haiku") {
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
            extra["fallbacks"] = "default"
        }
        let request = try SSEClient.makeRequest(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            headers: headers,
            body: extra.merging([
                "model": model,
                "max_tokens": 16000,
                "stream": true,
                "thinking": ["type": "adaptive"],
                "output_config": ["effort": "high"],
                "system": instructions,
                "messages": [["role": "user", "content": prompt]],
            ]) { _, new in new })

        var text = ""
        var stopReason: String?
        try await SSEClient.stream(request: request) { data in
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { return }
            switch type {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let piece = delta["text"] as? String {
                    text += piece
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    stopReason = delta["stop_reason"] as? String ?? stopReason
                }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
                throw TranscriptionError(message: "Claude API: \(message)")
            default:
                break
            }
        }
        if stopReason == "refusal" {
            throw TranscriptionError(message: "Claude API: the request was declined")
        }
        guard !text.isEmpty else {
            throw TranscriptionError(message: "Claude API: empty response")
        }
        return text
    }
}
