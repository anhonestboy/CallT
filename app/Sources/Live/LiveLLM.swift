import Foundation

/// Blocchi di contenuto per un modello multimodale.
enum LLMBlock: Sendable {
    case text(String)
    case jpeg(Data, caption: String)
}

/// Livello di modello: veloce per gli aggiornamenti durante la call, il
/// migliore per la stesura finale e per le risposte alle domande.
enum LLMTier: Sendable {
    case live, final, ask
}

/// Motore AI della sessione live. Ogni chiamata è indipendente (stateless):
/// le note correnti viaggiano nel prompt, quindi un errore o un riavvio non
/// perdono nulla e qualunque motore funziona allo stesso modo.
protocol LiveLLM: Sendable {
    var label: String { get }
    var supportsImages: Bool { get }
    func complete(system: String, blocks: [LLMBlock], tier: LLMTier) async throws -> String
}

enum LiveLLMFactory {
    /// "claude-cli" | "claude" | "notes" — con ripiego automatico se il motore
    /// scelto non è pronto.
    static func make() -> LiveLLM? {
        let preferred = AppSettings.liveEngine
        if preferred == "off" { return nil }
        let order: [String]
        switch preferred {
        case "claude": order = ["claude", "claude-cli", "notes"]
        case "notes": order = ["notes"]
        default: order = ["claude-cli", "claude", "notes"]
        }
        for id in order {
            if let engine = engine(id) {
                if id != preferred { appLog("ℹ️ Live AI engine “\(preferred)” not ready, using \(engine.label)") }
                return engine
            }
        }
        return nil
    }

    private static func engine(_ id: String) -> LiveLLM? {
        switch id {
        case "claude-cli":
            return ClaudeCLI.locate().map { ClaudeCLILLM(binary: $0) }
        case "claude":
            guard let key = KeychainStore.read(ClaudeNotesEngine.keychainAccount), !key.isEmpty else { return nil }
            return ClaudeAPILLM(apiKey: key)
        default:
            return CallNotesGenerator.activeEngine().map { NotesEngineLLM(engine: $0.engine, name: $0.name) }
        }
    }

    /// Alias dei modelli per livello, dalle impostazioni ("haiku"|"sonnet"|"opus").
    static func alias(for tier: LLMTier) -> String {
        switch tier {
        case .live: return AppSettings.liveModel
        case .final, .ask: return AppSettings.liveFinalModel
        }
    }
}

// MARK: - Claude via Claude Code (account locale, nessuna chiave API)

/// Usa la CLI `claude` installata e già autenticata (abbonamento Claude):
/// `claude -p` in modalità stream-json, senza strumenti, senza MCP, senza
/// impostazioni utente — solo il modello. Le immagini viaggiano come blocchi
/// base64 nello stesso formato dell'API.
enum ClaudeCLI {
    static func locate() -> String? {
        let custom = AppSettings.claudeCLIPath
        if !custom.isEmpty { return FileManager.default.isExecutableFile(atPath: custom) ? custom : nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Esegue una richiesta e ritorna il testo della risposta finale.
    static func run(
        binary: String, model: String, effort: String?, system: String, blocks: [LLMBlock],
        timeout: TimeInterval = 600
    ) async throws -> String {
        var content: [[String: Any]] = []
        for block in blocks {
            switch block {
            case .text(let text):
                content.append(["type": "text", "text": text])
            case .jpeg(let data, let caption):
                content.append(["type": "text", "text": caption])
                content.append(["type": "image", "source": [
                    "type": "base64", "media_type": "image/jpeg",
                    "data": data.base64EncodedString(),
                ]])
            }
        }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var input = try JSONSerialization.data(withJSONObject: message)
        input.append(0x0A)

        // Cartella di lavoro vuota: nessun CLAUDE.md o progetto viene caricato.
        let cwd = AppSettings.appSupportDir.appendingPathComponent("claude-cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        var args = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--model", model, "--tools", "", "--no-session-persistence",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
            "--setting-sources", "", "--disable-slash-commands",
            "--system-prompt", system,
        ]
        if let effort { args += ["--effort", effort] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                       env["PATH"] ?? ""].joined(separator: ":")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")  // usa l'account, non una chiave
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = LineCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            collector.ingest(handle.availableData)
        }
        let errCollector = LineCollector()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            errCollector.ingest(handle.availableData)
        }

        try process.run()
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async {
                        process.waitUntilExit()
                        cont.resume()
                    }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished { process.terminate() }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        collector.ingest(stdout.fileHandleForReading.readDataToEndOfFile())

        for line in collector.lines() {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "result" else { continue }
            if event["is_error"] as? Bool == true {
                let message = event["result"] as? String ?? "error"
                throw TranscriptionError(message: "Claude Code: \(message)")
            }
            if let result = event["result"] as? String, !result.isEmpty { return result }
        }
        if !finished { throw TranscriptionError(message: "Claude Code: timeout") }
        let tail = errCollector.lines().suffix(3).joined(separator: " ")
        throw TranscriptionError(message: "Claude Code: no answer (\(process.terminationStatus)) \(tail)")
    }

    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func ingest(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock(); data.append(chunk); lock.unlock()
        }
        func lines() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
    }
}

struct ClaudeCLILLM: LiveLLM {
    let binary: String
    var label: String { String(localized: "Claude (local account)") }
    var supportsImages: Bool { true }

    func complete(system: String, blocks: [LLMBlock], tier: LLMTier) async throws -> String {
        try await ClaudeCLI.run(
            binary: binary, model: LiveLLMFactory.alias(for: tier),
            effort: tier == .live ? "low" : nil, system: system, blocks: blocks)
    }
}

/// Motore note "Claude (account locale)" per la pipeline sui file.
struct ClaudeCLINotesEngine: NotesEngine {
    let binary: String
    let model: String
    let maxPromptChars = 500_000

    static func fromSettings() -> ClaudeCLINotesEngine? {
        ClaudeCLI.locate().map { ClaudeCLINotesEngine(binary: $0, model: AppSettings.notesModel(for: "claude-cli")) }
    }

    func generate(instructions: String, prompt: String) async throws -> String {
        try await ClaudeCLI.run(binary: binary, model: model, effort: nil,
                                system: instructions, blocks: [.text(prompt)])
    }
}

// MARK: - Claude API (chiave nel Portachiavi)

struct ClaudeAPILLM: LiveLLM {
    let apiKey: String
    var label: String { String(localized: "Claude API") }
    var supportsImages: Bool { true }

    static func modelID(_ alias: String) -> String {
        switch alias {
        case "haiku": return "claude-haiku-5-5"
        case "opus": return "claude-opus-5-5"
        default: return "claude-sonnet-5-5"
        }
    }

    func complete(system: String, blocks: [LLMBlock], tier: LLMTier) async throws -> String {
        let model = Self.modelID(LiveLLMFactory.alias(for: tier))
        var content: [[String: Any]] = []
        for block in blocks {
            switch block {
            case .text(let text):
                content.append(["type": "text", "text": text])
            case .jpeg(let data, let caption):
                content.append(["type": "text", "text": caption])
                content.append(["type": "image", "source": [
                    "type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString(),
                ]])
            }
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 32000,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": tier == .live ? "low" : "high"],
            "system": system,
            "messages": [["role": "user", "content": content]],
        ]
        var headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        // Ripiego automatico lato server se un classificatore rifiuta la richiesta.
        if model != "claude-haiku-5-5" {
            body["fallbacks"] = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }
        let request = try SSEClient.makeRequest(
            url: URL(string: "https://api.anthropic.com/v1/messages")!, headers: headers, body: body)
        var text = ""
        var stopReason: String?
        try await SSEClient.stream(request: request) { data in
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { return }
            switch type {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let piece = delta["text"] as? String { text += piece }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    stopReason = delta["stop_reason"] as? String ?? stopReason
                }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
                throw TranscriptionError(message: "Claude API: \(message)")
            default: break
            }
        }
        if stopReason == "refusal" {
            throw TranscriptionError(message: "Claude API: the request was declined")
        }
        guard !text.isEmpty else { throw TranscriptionError(message: "Claude API: empty response") }
        return text
    }
}

// MARK: - Qualunque motore delle note (solo testo: le immagini diventano OCR)

struct NotesEngineLLM: LiveLLM {
    let engine: NotesEngine
    let name: String
    var label: String { name }
    var supportsImages: Bool { false }

    func complete(system: String, blocks: [LLMBlock], tier: LLMTier) async throws -> String {
        let prompt = blocks.map { block -> String in
            switch block {
            case .text(let text): return text
            case .jpeg(_, let caption): return caption
            }
        }.joined(separator: "\n\n")
        // I motori piccoli (Apple, Ollama) hanno contesti ridotti: tiene la coda.
        let trimmed = prompt.count > engine.maxPromptChars
            ? String(prompt.suffix(engine.maxPromptChars)) : prompt
        return try await engine.generate(instructions: system, prompt: trimmed)
    }
}
