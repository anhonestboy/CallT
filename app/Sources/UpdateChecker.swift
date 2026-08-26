import Foundation
import AppKit

/// Controllo e installazione aggiornamenti via GitHub Releases
/// (leggero, niente framework: download del DMG, swap del bundle, riavvio).
@MainActor
enum UpdateChecker {
    private static let releasesAPI = "https://api.github.com/repos/anhonestboy/CallT/releases/latest"
    private static let releasesPage = "https://github.com/anhonestboy/CallT/releases/latest"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Controllo automatico (al massimo una volta al giorno, silenzioso se aggiornata).
    static func autoCheck() {
        let last = AppSettings.defaults.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        AppSettings.defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        Task {
            if let update = try? await latestNewerVersion() {
                Notifier.notify(
                    title: String(localized: "CallT \(update.version) is available"),
                    body: String(localized: "Choose “Check for updates” in Settings → General to install it."))
                appLog("⬆️ Update available: \(update.version)")
            }
        }
    }

    /// Controllo manuale con esito a schermo e installazione automatica.
    static func checkInteractively() async {
        do {
            if let update = try await latestNewerVersion() {
                let alert = NSAlert()
                alert.messageText = String(localized: "CallT \(update.version) is available")
                alert.informativeText = String(localized: "You are on \(currentVersion). CallT can install the update and relaunch automatically.")
                alert.addButton(withTitle: String(localized: "Install and relaunch"))
                alert.addButton(withTitle: String(localized: "Later"))
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try await installAndRelaunch(update)
            } else {
                let alert = NSAlert()
                alert.messageText = String(localized: "You're up to date")
                alert.informativeText = String(localized: "CallT \(currentVersion) is the latest version.")
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        } catch {
            appLog("⚠️ Update failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = String(localized: "Update failed")
            alert.informativeText = error.localizedDescription + "\n"
                + String(localized: "You can download it manually from the GitHub releases page.")
            alert.addButton(withTitle: String(localized: "Download"))
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: releasesPage)!)
            }
        }
    }

    struct Update: Sendable {
        let version: String
        let dmg: URL
    }

    /// Versione più recente sul repo (con l'URL del DMG) se maggiore
    /// di quella corrente, altrimenti nil.
    private static func latestNewerVersion() async throws -> Update? {
        var request = URLRequest(url: URL(string: releasesAPI)!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(remote, than: currentVersion) else { return nil }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let dmgString = assets
            .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
            ?? "https://github.com/anhonestboy/CallT/releases/download/\(tag)/CallT.dmg"
        guard let dmg = URL(string: dmgString) else { return nil }
        return Update(version: remote, dmg: dmg)
    }

    /// Scarica il DMG, estrae la nuova app, sostituisce il bundle corrente
    /// (con ripristino in caso di errore) e riavvia.
    private static func installAndRelaunch(_ update: Update) async throws {
        let fm = FileManager.default
        appLog("⬇️ Downloading CallT \(update.version)…")
        let (downloaded, response) = try await URLSession.shared.download(from: update.dmg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TranscriptionError(message: "download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }

        let work = fm.temporaryDirectory.appendingPathComponent("callt-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let dmgFile = work.appendingPathComponent("CallT.dmg")
        try fm.moveItem(at: downloaded, to: dmgFile)

        // Monta il DMG e copia l'app in un'area di lavoro, poi smonta comunque.
        appLog("📦 Installing CallT \(update.version)…")
        let mount = work.appendingPathComponent("mnt")
        let attach = try await ProcessRunner.run(
            "/usr/bin/hdiutil",
            ["attach", dmgFile.path, "-nobrowse", "-noverify", "-readonly", "-mountpoint", mount.path])
        guard attach.status == 0 else {
            throw TranscriptionError(message: "hdiutil attach failed: \(attach.stderr)")
        }
        let staged = work.appendingPathComponent("CallT.app")
        var stageError: Error?
        let newApp = mount.appendingPathComponent("CallT.app")
        if !fm.fileExists(atPath: newApp.path) {
            stageError = TranscriptionError(message: "CallT.app not found in the update image")
        } else {
            let copy = try await ProcessRunner.run("/usr/bin/ditto", [newApp.path, staged.path])
            if copy.status != 0 {
                stageError = TranscriptionError(message: "ditto failed: \(copy.stderr)")
            }
        }
        _ = try? await ProcessRunner.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        if let stageError { throw stageError }

        let stagedVersion = Bundle(url: staged)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard stagedVersion == update.version else {
            throw TranscriptionError(message: "downloaded app is \(stagedVersion ?? "unknown"), expected \(update.version)")
        }
        _ = try? await ProcessRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        // Swap: sposta da parte il bundle in esecuzione, installa il nuovo,
        // ripristina il vecchio se qualcosa va storto.
        let current = Bundle.main.bundleURL
        let backup = current.deletingLastPathComponent()
            .appendingPathComponent(".CallT-\(currentVersion).old.app")
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: current, to: backup)
        let install = try await ProcessRunner.run("/usr/bin/ditto", [staged.path, current.path])
        guard install.status == 0 else {
            try? fm.removeItem(at: current)
            try? fm.moveItem(at: backup, to: current)
            throw TranscriptionError(message: "install failed: \(install.stderr)")
        }
        try? fm.removeItem(at: backup)

        appLog("✅ CallT \(update.version) installed — relaunching")
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(current.path)\""]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
