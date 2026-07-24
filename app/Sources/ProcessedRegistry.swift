import Foundation

/// Registro persistente dei file già elaborati (o visti): evita ri-elaborazioni
/// al riavvio e permette di distinguere i file preesistenti dai nuovi arrivi.
actor ProcessedRegistry {
    struct Entry: Codable {
        var size: Int64
        var mtime: Date
        var processedAt: Date?
        var status: String  // "done" | "failed" | "seen"
        var transcript: String?
    }

    static let shared = ProcessedRegistry()

    private var entries: [String: Entry] = [:]
    private let fileURL = AppSettings.appSupportDir.appendingPathComponent("registry.json")
    private var loaded = false

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func stat(_ url: URL) -> (size: Int64, mtime: Date)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        return (size, mtime)
    }

    /// Il file è già noto (elaborato, fallito o marcato come visto) e non è
    /// cambiato da allora? Un file sostituito/modificato (dimensione o mtime
    /// diversi) torna elaborabile, anche se un tentativo precedente era fallito.
    func isKnown(_ url: URL) -> Bool {
        knownStatus(url) != nil
    }

    /// Come isKnown, ma ritorna lo stato registrato ("done" | "failed" | "seen")
    /// per permettere messaggi distinti, o nil se il file va elaborato.
    func knownStatus(_ url: URL) -> String? {
        loadIfNeeded()
        guard let entry = entries[url.path], let s = Self.stat(url),
              entry.size == s.size,
              abs(entry.mtime.timeIntervalSince(s.mtime)) < 1.0
        else { return nil }
        return entry.status
    }

    /// Trascrizione già associata a questo file sorgente (se elaborato con successo).
    func knownTranscript(for url: URL) -> String? {
        loadIfNeeded()
        guard let entry = entries[url.path], entry.status == "done" else { return nil }
        return entry.transcript
    }

    struct RecentItem: Sendable {
        let sourcePath: String
        let transcriptPath: String?
        let processedAt: Date
        var displayName: String { (sourcePath as NSString).lastPathComponent }
    }

    /// Ultimi file elaborati con successo, dal più recente.
    func recentDone(limit: Int) -> [RecentItem] {
        loadIfNeeded()
        return entries
            .compactMap { path, entry -> RecentItem? in
                guard entry.status == "done", let at = entry.processedAt else { return nil }
                return RecentItem(sourcePath: path, transcriptPath: entry.transcript, processedAt: at)
            }
            .sorted { $0.processedAt > $1.processedAt }
            .prefix(limit)
            .map { $0 }
    }

    func markSeen(_ url: URL) {
        loadIfNeeded()
        guard let s = Self.stat(url) else { return }
        if entries[url.path] == nil {
            entries[url.path] = Entry(size: s.size, mtime: s.mtime, processedAt: nil, status: "seen", transcript: nil)
            save()
        }
    }

    func markDone(_ url: URL, transcript: URL?) {
        loadIfNeeded()
        guard let s = Self.stat(url) else { return }
        entries[url.path] = Entry(size: s.size, mtime: s.mtime, processedAt: Date(), status: "done", transcript: transcript?.path)
        save()
    }

    func markFailed(_ url: URL) {
        loadIfNeeded()
        guard let s = Self.stat(url) else { return }
        entries[url.path] = Entry(size: s.size, mtime: s.mtime, processedAt: Date(), status: "failed", transcript: nil)
        save()
    }

    func forget(_ url: URL) {
        loadIfNeeded()
        entries[url.path] = nil
        save()
    }
}
