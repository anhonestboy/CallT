import Foundation

/// Motore note per endpoint OpenAI-compatibili (chat/completions):
/// copre OpenRouter, DeepSeek, Ollama locale e qualunque endpoint custom
/// (OpenAI incluso), tramite preset con URL e default sensati.
struct OpenAICompatEngine: NotesEngine {
    struct Provider {
        let id: String
        let label: String
        let baseURL: String?          // nil = richiesto all'utente (custom)
        let defaultModel: String
        let needsKey: Bool
        let maxPromptChars: Int
    }

    static let providers: [Provider] = [
        .init(id: "openrouter", label: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
              defaultModel: "anthropic/claude-sonnet-4.5", needsKey: true, maxPromptChars: 150_000),
        .init(id: "deepseek", label: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
              defaultModel: "deepseek-chat", needsKey: true, maxPromptChars: 150_000),
        .init(id: "ollama", label: "Ollama (locale)", baseURL: "http://localhost:11434/v1",
              defaultModel: "llama3.2", needsKey: false, maxPromptChars: 20_000),
        .init(id: "custom", label: "OpenAI-compatibile…", baseURL: nil,
              defaultModel: "", needsKey: true, maxPromptChars: 100_000),
    ]

    static func provider(_ id: String) -> Provider? {
        providers.first { $0.id == id }
    }

    let baseURL: URL
    let apiKey: String?
    let model: String
    let maxPromptChars: Int

    static func fromSettings(providerID: String) -> OpenAICompatEngine? {
        guard let provider = provider(providerID) else { return nil }
        let rawURL = provider.baseURL ?? AppSettings.notesBaseURL
        guard !rawURL.isEmpty, let base = URL(string: rawURL) else { return nil }
        let model = AppSettings.notesModel(for: providerID)
        guard !model.isEmpty else { return nil }
        let key = KeychainStore.read("apikey-\(providerID)")
        if provider.needsKey && (key ?? "").isEmpty { return nil }
        return OpenAICompatEngine(
            baseURL: base, apiKey: key, model: model,
            maxPromptChars: provider.maxPromptChars)
    }

    func generate(instructions: String, prompt: String) async throws -> String {
        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        let request = try SSEClient.makeRequest(
            url: baseURL.appendingPathComponent("chat/completions"),
            headers: headers,
            body: [
                "model": model,
                "stream": true,
                "max_tokens": 8192,
                "messages": [
                    ["role": "system", "content": instructions],
                    ["role": "user", "content": prompt],
                ],
            ])

        var text = ""
        try await SSEClient.stream(request: request) { data in
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let error = event["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "unknown error"
                throw TranscriptionError(message: "API: \(message)")
            }
            if let choices = event["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let piece = delta["content"] as? String {
                text += piece
            }
        }
        guard !text.isEmpty else {
            throw TranscriptionError(message: "empty response from model \(model)")
        }
        return text
    }
}
