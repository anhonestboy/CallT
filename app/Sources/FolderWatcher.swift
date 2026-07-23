import Foundation

/// Osserva una cartella per file video. Quando un file appare (o viene
/// sostituito), attende che la dimensione sia stabile (registrazione
/// terminata) e poi lo consegna al callback. La deduplica dei file già
/// elaborati è compito del chiamante (ProcessedRegistry).
final class FolderWatcher: @unchecked Sendable {
    static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "m4v"]
    /// Anche i file solo-audio vengono trascritti (registrazioni, memo, ecc.).
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "flac", "caf"]
    static var mediaExtensions: Set<String> { videoExtensions.union(audioExtensions) }

    private let folder: URL
    private let onStableFile: @Sendable (URL) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let queue = DispatchQueue(label: "com.werootbox.callt.watcher")
    /// File in attesa di stabilizzazione (accesso solo su `queue`).
    private var pending: Set<String> = []
    /// Invalida i check programmati delle sessioni precedenti (accesso su `queue`).
    private var generation = 0

    init(folder: URL, onStableFile: @escaping @Sendable (URL) -> Void) {
        self.folder = folder
        self.onStableFile = onStableFile
    }

    static func isVideo(_ url: URL) -> Bool {
        mediaExtensions.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.hasPrefix(".")
    }

    func currentVideos() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { Self.isVideo($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Avvia l'osservazione. Anche i file già presenti passano dal controllo
    /// di stabilità: quelli già elaborati verranno scartati dal registro,
    /// mentre una registrazione ancora in corso verrà presa quando finisce.
    func start() -> Bool {
        stop()
        descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend], queue: queue)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [descriptor] in close(descriptor) }
        src.resume()
        source = src
        queue.async { [weak self] in self?.scan() }
        return true
    }

    func stop() {
        queue.sync {
            generation += 1
            pending.removeAll()
        }
        source?.cancel()
        source = nil
        descriptor = -1
    }

    /// Su `queue`: riallinea `pending` col disco e arma i controlli di
    /// stabilità per i file nuovi.
    private func scan() {
        let onDisk = currentVideos()
        pending.formIntersection(Set(onDisk.map(\.path)))
        for url in onDisk where !pending.contains(url.path) {
            pending.insert(url.path)
            waitForStability(url, generation: generation)
        }
    }

    /// Dichiara stabile un file solo dopo 3 campioni identici consecutivi
    /// (~6s): protegge dalle copie lente che si fermano per qualche secondo.
    /// Timeout complessivo 2 ore per registrazioni scritte in streaming.
    private func waitForStability(
        _ url: URL, generation gen: Int,
        lastSize: Int64? = nil, stableCount: Int = 0, checksRemaining: Int = 3600
    ) {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, gen == self.generation else { return }
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.pending.remove(url.path)
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
                .flatMap { $0 } ?? 0
            if let last = lastSize, size == last, size > 0 {
                if stableCount + 1 >= 3 {
                    // Rimosso da pending PRIMA della consegna: se in futuro lo
                    // stesso path viene sovrascritto, verrà rilevato di nuovo.
                    self.pending.remove(url.path)
                    self.onStableFile(url)
                } else {
                    self.waitForStability(
                        url, generation: gen, lastSize: size,
                        stableCount: stableCount + 1, checksRemaining: checksRemaining - 1)
                }
            } else if checksRemaining > 0 {
                self.waitForStability(
                    url, generation: gen, lastSize: size,
                    stableCount: 0, checksRemaining: checksRemaining - 1)
            } else {
                self.pending.remove(url.path)
                appLog("⚠️ Timed out waiting for file: \(url.lastPathComponent)")
            }
        }
    }
}
