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
            ("claude-opus-4-8", String(localized: "Claude Opus 4.8 (best)")),
            ("claude-sonnet-5", "Claude Sonnet 5"),
            ("claude-haiku-4-5", String(localized: "Claude Haiku 4.5 (budget)")),
        ]
    }

    static func fromSettings() -> ClaudeNotesEngine? {
        guard let key = KeychainStore.read(keychainAccount), !key.isEmpty else { return nil }
        return ClaudeNotesEngine(apiKey: key, model: AppSettings.notesModel(for: "claude"))
    }

    func generate(instructions: String, prompt: String) async throws -> String {
        let request = try SSEClient.makeRequest(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ],
            body: [
                "model": model,
                "max_tokens": 16000,
                "stream": true,
                "thinking": ["type": "adaptive"],
                "system": instructions,
                "messages": [["role": "user", "content": prompt]],
            ])

        var text = ""
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
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
                throw TranscriptionError(message: "Claude API: \(message)")
            default:
                break
            }
        }
        guard !text.isEmpty else {
            throw TranscriptionError(message: "Claude API: empty response")
        }
        return text
    }
}
