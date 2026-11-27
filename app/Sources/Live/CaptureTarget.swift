import Foundation
import AppKit
import ScreenCaptureKit

/// Cosa catturare per gli screenshot e le clip. Di default cerca la finestra
/// della call (Zoom, Teams, Meet nel browser…): catturare solo quella evita
/// notifiche, altri monitor e il pannello di Recap, e funziona anche se la
/// finestra è parzialmente coperta.
enum CaptureTargetChoice: String, CaseIterable, Identifiable {
    case auto          // finestra della call, altrimenti lo schermo col puntatore
    case pointerDisplay
    case mainDisplay

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return String(localized: "Automatic (the call window, otherwise the screen with the pointer)")
        case .pointerDisplay: return String(localized: "The screen with the pointer")
        case .mainDisplay: return String(localized: "The main screen")
        }
    }
}

struct ResolvedCaptureTarget: @unchecked Sendable {
    let filter: SCContentFilter
    /// Dimensione in pixel del frame catturato (pari, limitata a 2560 di lato).
    let pixelSize: CGSize
    let description: String
    let isWindow: Bool
}

enum CaptureTargetResolver {
    private static let nativeCallApps: [String: [String]] = [
        "us.zoom.xos": ["meeting", "riunione", "webinar", "zoom meeting"],
        "com.microsoft.teams2": ["meeting", "riunione", "call", "chiamata"],
        "com.microsoft.teams": ["meeting", "riunione", "call", "chiamata"],
        "com.apple.FaceTime": [""],
        "com.cisco.webexmeetingsapp": [""],
        "Cisco-Systems.Spark": ["meeting", "riunione"],
        "com.tinyspeck.slackmacgap": ["huddle"],
    ]
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.apple.Safari", "org.mozilla.firefox",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    private static let browserTitleHints = [
        "meet - ", "meet – ", "google meet", "meet.google", "microsoft teams",
        "zoom meeting", "whereby", "jitsi", "webex",
    ]

    static func resolve(_ choice: CaptureTargetChoice) async throws -> ResolvedCaptureTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if choice == .auto, let window = callWindow(in: content.windows) {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let app = window.owningApplication?.applicationName ?? "?"
            let title = window.title.map { $0.isEmpty ? "" : " — \($0)" } ?? ""
            return ResolvedCaptureTarget(
                filter: filter, pixelSize: pixelSize(for: filter),
                description: String(localized: "Window: \(app)\(title)"), isWindow: true)
        }
        let display = pickDisplay(content.displays, preferPointer: choice != .mainDisplay)
        guard let display else {
            throw TranscriptionError(message: String(localized: "no display available"))
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let name = NSScreen.screens.first { $0.displayID == display.displayID }?.localizedName ?? "Display"
        return ResolvedCaptureTarget(
            filter: filter, pixelSize: pixelSize(for: filter),
            description: String(localized: "Screen: \(name)"), isWindow: false)
    }

    /// Filtro scelto dall'utente con il picker di sistema.
    static func fromPicked(_ filter: SCContentFilter) -> ResolvedCaptureTarget {
        ResolvedCaptureTarget(
            filter: filter, pixelSize: pixelSize(for: filter),
            description: String(localized: "Chosen window or screen"), isWindow: filter.style == .window)
    }

    /// La finestra di call più grande tra quelle riconosciute.
    static func callWindow(in windows: [SCWindow]) -> SCWindow? {
        let candidates = windows.filter { window in
            guard window.isOnScreen, window.windowLayer == 0,
                  window.frame.width >= 320, window.frame.height >= 240,
                  let bundle = window.owningApplication?.bundleIdentifier
            else { return false }
            let title = (window.title ?? "").lowercased()
            if let hints = nativeCallApps[bundle] {
                return hints.contains { $0.isEmpty || title.contains($0) }
            }
            if browsers.contains(bundle) {
                return browserTitleHints.contains { title.contains($0) }
            }
            return false
        }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func pickDisplay(_ displays: [SCDisplay], preferPointer: Bool) -> SCDisplay? {
        if preferPointer {
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
               let match = displays.first(where: { $0.displayID == screen.displayID }) {
                return match
            }
        }
        if let main = NSScreen.main?.displayID, let match = displays.first(where: { $0.displayID == main }) {
            return match
        }
        return displays.first
    }

    private static func pixelSize(for filter: SCContentFilter) -> CGSize {
        let rect = filter.contentRect
        let scale = CGFloat(max(1, filter.pointPixelScale))
        var width = max(rect.width * scale, 640)
        var height = max(rect.height * scale, 360)
        let maxSide: CGFloat = 2560
        if max(width, height) > maxSide {
            let k = maxSide / max(width, height)
            width *= k
            height *= k
        }
        return CGSize(width: CGFloat(Int(width) & ~1), height: CGFloat(Int(height) & ~1))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
