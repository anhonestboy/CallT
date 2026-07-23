import Foundation

/// Integrazione con Comandi Apple via CLI /usr/bin/shortcuts.
enum ShortcutRunner {
    static let shortcutsBin = "/usr/bin/shortcuts"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: shortcutsBin)
    }

    /// Elenco dei comandi disponibili (nomi).
    static func list() async -> [String] {
        guard let result = try? await ProcessRunner.run(shortcutsBin, ["list"], timeout: 30),
              result.status == 0
        else { return [] }
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Esegue un comando passando il file come input.
    /// Ritorna nil in caso di successo, altrimenti il messaggio di errore.
    static func run(shortcut: String, input: URL) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                shortcutsBin, ["run", shortcut, "-i", input.path], timeout: 180)
            guard result.status == 0 else {
                let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return msg.isEmpty ? "exit \(result.status)" : msg
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
