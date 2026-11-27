import Foundation
import AppKit

/// Si accorge (in modo euristico) di quando stai condividendo lo schermo, così
/// il pannello di CallT si nasconde da solo e ricompare alla fine.
///
/// macOS non espone un'API "c'è una condivisione in corso": le app di call
/// però mostrano finestre riconoscibili (la barra "meet.google.com sta
/// condividendo il tuo schermo", la toolbar di condivisione di Zoom/Teams).
/// Leggere i titoli delle finestre richiede il permesso di registrazione
/// schermo, che CallT ha già.
@MainActor
final class ScreenShareWatcher: ObservableObject {
    static let shared = ScreenShareWatcher()

    @Published private(set) var isSharing = false
    private var timer: Timer?
    private var lastLogged = ""

    private static let titleHints = [
        "is sharing your screen", "is sharing a window", "is sharing this tab",
        "sta condividendo il tuo schermo", "sta condividendo lo schermo",
        "sta condividendo una finestra", "sta condividendo questa scheda",
        "stop sharing", "interrompi condivisione", "smetti di condividere",
        "you are screen sharing", "you're sharing", "stai condividendo",
        "sharing control bar", "barra di controllo della condivisione",
        "zoom share", "share toolbar", "sharing toolbar", "screen sharing",
        "condivisione schermo", "you are presenting", "stai presentando",
    ]
    private static let ignoredOwners: Set<String> = ["CallT", "Window Server", "Dock", "Control Center"]

    func start() {
        stop()
        guard AppSettings.liveHideOnShare else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in ScreenShareWatcher.shared.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isSharing { isSharing = false }
    }

    private func check() {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        var match: String?
        for window in info {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            guard !Self.ignoredOwners.contains(owner) else { continue }
            let title = (window[kCGWindowName as String] as? String ?? "").lowercased()
            guard !title.isEmpty else { continue }
            if Self.titleHints.contains(where: { title.contains($0) }) {
                match = "\(owner): \(title)"
                break
            }
        }
        let sharing = match != nil
        if sharing != isSharing {
            isSharing = sharing
            if let match, match != lastLogged {
                lastLogged = match
                appLog("🖥️ Screen sharing detected (\(match)): hiding the panel")
            } else if !sharing {
                appLog("🖥️ Screen sharing ended: panel restored")
            }
        }
    }
}
