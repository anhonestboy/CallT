import Foundation
import AppKit
import UniformTypeIdentifiers

/// Stato centrale dell'app: monitoraggio, coda seriale di elaborazione, jobs per la UI.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var isMonitoring = false
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var queuedCount = 0

    private var watcher: FolderWatcher?
    private var pendingQueue: [URL] = []
    private var isProcessing = false
    private static let maxVisibleJobs = 12

    var currentJob: Job? { jobs.last(where: { !$0.isFinished }) }

    // MARK: - Avvio

    func onLaunch() {
        AppSettings.registerDefaults()
        Notifier.requestPermissionIfNeeded()
        appLog("CallT started")
        if AppSettings.monitoringEnabled {
            startMonitoring()
        }
    }

    // MARK: - Monitoraggio

    func toggleMonitoring() {
        isMonitoring ? stopMonitoring() : startMonitoring()
    }

    func startMonitoring() {
        stopMonitoring()
        let folder = AppSettings.watchFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let newWatcher = FolderWatcher(folder: folder) { url in
            Task { @MainActor in AppState.shared.enqueue(url) }
        }
        // Solo alla PRIMA attivazione su questa cartella i file già presenti
        // vengono sigillati come "visti" (si elaborano solo i nuovi arrivi).
        // Ai riavvii successivi niente sigillo: i file arrivati ad app chiusa
        // o interrotti a metà elaborazione vengono ripresi automaticamente.
        var initialized = AppSettings.defaults.stringArray(forKey: SettingsKey.initializedFolders) ?? []
        if !initialized.contains(folder.path) {
            let existing = newWatcher.currentVideos()
            Task.detached {
                for url in existing { await ProcessedRegistry.shared.markSeen(url) }
            }
            initialized.append(folder.path)
            AppSettings.defaults.set(initialized, forKey: SettingsKey.initializedFolders)
        }
        guard newWatcher.start() else {
            appLog("❌ Could not watch the folder: \(folder.path)")
            return
        }
        watcher = newWatcher
        isMonitoring = true
        AppSettings.defaults.set(true, forKey: SettingsKey.monitoringEnabled)
        appLog("🔍 Monitoring active: \(folder.path)")
    }

    func stopMonitoring() {
        watcher?.stop()
        watcher = nil
        if isMonitoring {
            isMonitoring = false
            AppSettings.defaults.set(false, forKey: SettingsKey.monitoringEnabled)
            appLog("⏸️ Monitoring stopped")
        }
    }

    /// Da chiamare quando l'utente cambia la cartella osservata nelle impostazioni.
    func watchFolderChanged() {
        if isMonitoring { startMonitoring() }
    }

    // MARK: - Coda

    /// Path già segnalati come "saltati" (per non riempire il log a ogni evento).
    private var loggedSkips: Set<String> = []

    /// Accoda un file. `force` salta il controllo "già elaborato".
    func enqueue(_ url: URL, force: Bool = false) {
        Task { @MainActor in
            // Mai auto-elaborare i nostri stessi output (es. se la cartella
            // di output coincide con quella osservata).
            let stem = url.deletingPathExtension().lastPathComponent
            if !force, stem.hasSuffix("_compressed") || stem.hasSuffix("_audio") {
                return
            }
            if !force, let status = await ProcessedRegistry.shared.knownStatus(url) {
                if loggedSkips.insert(url.path).inserted {
                    switch status {
                    case "seen":
                        appLog("↩️ Pre-existing, not processed: \(url.lastPathComponent) (menu → Process existing files)")
                    case "failed":
                        appLog("↩️ Previous attempt failed, skipping: \(url.lastPathComponent) (retry from the menu)")
                    default:
                        appLog("↩️ Already processed, skipping: \(url.lastPathComponent)")
                    }
                }
                return
            }
            guard !pendingQueue.contains(url),
                  currentJob?.videoURL != url else { return }
            pendingQueue.append(url)
            queuedCount = pendingQueue.count
            appLog("📥 Queued: \(url.lastPathComponent)")
            processNextIfIdle()
        }
    }

    /// Elabora manualmente file scelti dall'utente (dialogo di selezione).
    func enqueueManually() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie, .movie, .audio, .mpeg4Audio, .wav, .mp3]
        if let mkv = UTType(filenameExtension: "mkv") { types.append(mkv) }
        panel.allowedContentTypes = types
        panel.message = String(localized: "Choose the files to transcribe")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { enqueue(url, force: true) }
    }

    /// Ri-elabora i file già presenti nella cartella osservata.
    func processExistingFiles() {
        let folder = AppSettings.watchFolder
        let files = FolderWatcher(folder: folder, onStableFile: { _ in }).currentVideos()
        guard !files.isEmpty else {
            appLog("ℹ️ No media files in the watched folder")
            return
        }
        for url in files { enqueue(url, force: true) }
    }

    private func processNextIfIdle() {
        guard !isProcessing, !pendingQueue.isEmpty else { return }
        let url = pendingQueue.removeFirst()
        queuedCount = pendingQueue.count
        isProcessing = true

        var job = Job(videoURL: url)
        job.startedAt = Date()
        jobs.append(job)
        if jobs.count > Self.maxVisibleJobs { jobs.removeFirst(jobs.count - Self.maxVisibleJobs) }
        let jobID = job.id

        Task.detached(priority: .userInitiated) {
            await Pipeline.run(videoURL: url) { stage, progress, info in
                Task { @MainActor in
                    AppState.shared.updateJob(jobID, stage: stage, progress: progress, info: info)
                }
            }
            Task { @MainActor in
                AppState.shared.finishCurrentAndContinue()
            }
        }
    }

    private func finishCurrentAndContinue() {
        isProcessing = false
        processNextIfIdle()
    }

    private func updateJob(_ id: UUID, stage: JobStage, progress: Double, info: Pipeline.UpdateInfo?) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        // Gli stati done/failed sono terminali: ignora update in ritardo.
        guard !jobs[idx].isFinished else { return }
        jobs[idx].stage = stage
        jobs[idx].progress = progress
        if let info {
            jobs[idx].error = info.error
            jobs[idx].transcriptURL = info.transcriptURL ?? jobs[idx].transcriptURL
        }
        if stage == .done || stage == .failed {
            jobs[idx].finishedAt = Date()
        }
    }

    // MARK: - Azioni varie

    func openWatchFolder() {
        NSWorkspace.shared.open(AppSettings.watchFolder)
    }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(at: AppSettings.outputFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AppSettings.outputFolder)
    }

    func quit() {
        // Ferma il watcher SENZA toccare la preferenza monitoringEnabled:
        // se era attivo, deve riprendere da solo al prossimo avvio.
        watcher?.stop()
        watcher = nil
        NSApp.terminate(nil)
    }
}
