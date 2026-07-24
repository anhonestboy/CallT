import Foundation
import AppKit

/// Controllo aggiornamenti via GitHub Releases (leggero, niente framework).
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
            if let newer = try? await latestNewerVersion() {
                Notifier.notify(
                    title: String(localized: "CallT \(newer) is available"),
                    body: String(localized: "Download it from the GitHub releases page."))
                appLog("⬆️ Update available: \(newer)")
            }
        }
    }

    /// Controllo manuale con esito a schermo.
    static func checkInteractively() async {
        do {
            if let newer = try await latestNewerVersion() {
                let alert = NSAlert()
                alert.messageText = String(localized: "CallT \(newer) is available")
                alert.informativeText = String(localized: "You are on \(currentVersion). Download the update from GitHub.")
                alert.addButton(withTitle: String(localized: "Download"))
                alert.addButton(withTitle: String(localized: "Later"))
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: releasesPage)!)
                }
            } else {
                let alert = NSAlert()
                alert.messageText = String(localized: "You're up to date")
                alert.informativeText = String(localized: "CallT \(currentVersion) is the latest version.")
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        } catch {
            appLog("⚠️ Update check failed: \(error.localizedDescription)")
        }
    }

    /// Versione più recente sul repo se maggiore di quella corrente, altrimenti nil.
    private static func latestNewerVersion() async throws -> String? {
        var request = URLRequest(url: URL(string: releasesAPI)!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return isNewer(remote, than: currentVersion) ? remote : nil
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
