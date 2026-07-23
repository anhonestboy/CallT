import Foundation
import os.log

/// Log in memoria (per la UI) + su file in Application Support/CallT/callt.log.
@MainActor
final class LogStore: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    static let shared = LogStore()

    @Published private(set) var lines: [Line] = []
    private var nextID = 0
    private let fileURL = AppSettings.appSupportDir.appendingPathComponent("callt.log")
    private let osLog = Logger(subsystem: "com.werootbox.callt", category: "app")
    private static let maxLines = 500

    var logFileURL: URL { fileURL }

    func log(_ message: String) {
        append(message)
    }

    private func append(_ message: String) {
        let ts = Self.timeFormatter.string(from: Date())
        let line = "[\(ts)] \(message)"
        lines.append(Line(id: nextID, text: line))
        nextID += 1
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        osLog.info("\(message, privacy: .public)")
        appendToFile(line + "\n")
    }

    private func appendToFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
            return
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            // Ruota il file oltre i 2 MB per non crescere all'infinito.
            if let size = try? handle.seekToEnd(), size > 2_000_000 {
                try? data.write(to: fileURL)
                return
            }
            try? handle.write(contentsOf: data)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Scorciatoia globale usata dal codice non-UI (hop sul MainActor).
func appLog(_ message: String) {
    Task { @MainActor in
        LogStore.shared.log(message)
    }
}
