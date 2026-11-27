import SwiftUI
import AppKit
import ScreenCaptureKit

/// Collaudo della modalità live senza una call vera:
///
///   CallT --live-replay <file> [--speed 1] [--live-test-actions] [--render-ui <dir>] [--quit-after-session]
///
/// `--live-test-actions` esegue durante il replay screenshot, clip, momento
/// segnato, nota e domanda; `--render-ui` salva PNG della UI reale (popover e
/// pannello) in vari stati.
@MainActor
enum LiveDebug {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--live-replay"), args.count > idx + 1 else { return }
        let url = URL(fileURLWithPath: args[idx + 1])
        var speed = 1.0
        if let s = args.firstIndex(of: "--speed"), args.count > s + 1 { speed = Double(args[s + 1]) ?? 1 }
        let actions = args.contains("--live-test-actions")
        let renderDir = args.firstIndex(of: "--render-ui").flatMap { args.count > $0 + 1 ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let quitAfter = args.contains("--quit-after-session")
        let glassDir = args.firstIndex(of: "--render-glass").flatMap { args.count > $0 + 1 ? URL(fileURLWithPath: args[$0 + 1]) : nil }

        Task { @MainActor in
            let session = LiveSession.shared
            await session.start(mode: .video, replay: url, replaySpeed: speed)
            if actions { scheduleActions(speed: speed) }
            if let renderDir {
                try? FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)
                try? await Task.sleep(nanoseconds: UInt64(42 / speed * 1_000_000_000))
                await renderLive(into: renderDir)
            }
            if let glassDir {
                try? FileManager.default.createDirectory(at: glassDir, withIntermediateDirectories: true)
                try? await Task.sleep(nanoseconds: UInt64(40 / speed * 1_000_000_000))
                await renderGlass(into: glassDir)
            }
            while !session.isDoneOrFailed { try? await Task.sleep(nanoseconds: 500_000_000) }
            if let renderDir { await renderDone(into: renderDir) }
            if quitAfter {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                exit(0)
            }
        }
    }

    private static func scheduleActions(speed: Double) {
        func at(_ seconds: Double, _ action: @escaping @MainActor () async -> Void) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds / speed * 1_000_000_000))
                await action()
            }
        }
        let session = LiveSession.shared
        at(18) { appLog("🧪 snapshot"); await session.snapshot(note: "test") }
        at(36) { appLog("🧪 clip"); await session.clip() }
        at(48) { appLog("🧪 mark"); await session.markMoment(note: "Decisione importante sul CRM") }
        at(52) { appLog("🧪 note"); session.addUserNote("Ricordarmi di chiedere a Marco i costi del CRM") }
        at(66) { appLog("🧪 ask"); await session.ask("Qual è il budget e cosa copre?") }
    }

    /// Fotografa il pannello vero (vetro incluso) sopra uno sfondo creato qui:
    /// la cattura include solo le finestre di CallT, mai il resto dello schermo.
    private static func renderGlass(into dir: URL) async {
        let controller = LivePanelController.shared
        for (expanded, tab, name) in [(false, LivePanelTab.notes, "glass-compact"),
                                      (true, .notes, "glass-notes"), (true, .transcript, "glass-transcript"),
                                      (true, .chat, "glass-chat")] {
            controller.expanded = expanded
            controller.tab = tab
            controller.show()
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let panel = NSApp.windows.first(where: { $0 is LivePanelWindow }) else { continue }
            if let visible = panel.screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                             y: visible.midY - panel.frame.height / 2))
            }
            let backdrop = NSWindow(contentRect: panel.frame.insetBy(dx: -60, dy: -60),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
            backdrop.level = NSWindow.Level(rawValue: panel.level.rawValue - 1)
            backdrop.contentView = NSHostingView(rootView: Backdrop())
            backdrop.orderFrontRegardless()
            panel.sharingType = .readOnly  // solo per la foto di collaudo
            panel.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 900_000_000)
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let mine = content.windows.filter {
                    $0.windowID == CGWindowID(panel.windowNumber) || $0.windowID == CGWindowID(backdrop.windowNumber)
                }
                if let display = content.displays.first(where: { $0.displayID == panel.screen?.displayID }) ?? content.displays.first,
                   mine.count == 2 {
                    let filter = SCContentFilter(display: display, including: mine)
                    let config = SCStreamConfiguration()
                    let scale = panel.screen?.backingScaleFactor ?? 2
                    // Coordinate SCK: origine in alto a sinistra dello schermo.
                    let screenH = panel.screen?.frame.height ?? 0
                    let f = backdrop.frame
                    config.sourceRect = CGRect(x: f.minX - (panel.screen?.frame.minX ?? 0),
                                               y: screenH - f.maxY + (panel.screen?.frame.minY ?? 0),
                                               width: f.width, height: f.height)
                    config.width = Int(f.width * scale)
                    config.height = Int(f.height * scale)
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let rep = NSBitmapImageRep(cgImage: image)
                    try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
                }
            } catch {
                appLog("⚠️ glass render: \(error.localizedDescription)")
            }
            backdrop.orderOut(nil)
            panel.sharingType = .none
        }
        controller.expanded = false
    }

    private struct Backdrop: View {
        var body: some View {
            ZStack {
                LinearGradient(colors: [.indigo, .teal, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(0..<14, id: \.self) { i in
                        Text(verbatim: "Quarterly review — slide \(i + 1) · revenue +12% · roadmap")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
        }
    }

    private static func renderLive(into dir: URL) async {
        let session = LiveSession.shared
        let controller = LivePanelController.shared
        controller.expanded = false
        await snap(panel(session, controller, width: nil), "panel-compact.png", dir)
        controller.expanded = true
        for tab in LivePanelTab.allCases {
            controller.tab = tab
            await snap(panel(session, controller, width: 440, height: 640), "panel-live-\(tab.rawValue).png", dir)
        }
        await snap(PopoverView().environmentObject(AppState.shared)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)), "popover-live.png", dir)
        controller.expanded = false
    }

    private static func renderDone(into dir: URL) async {
        let session = LiveSession.shared
        let controller = LivePanelController.shared
        controller.expanded = true
        for tab in LivePanelTab.allCases {
            controller.tab = tab
            await snap(panel(session, controller, width: 440, height: 720), "panel-done-\(tab.rawValue).png", dir)
        }
        await snap(PopoverView().environmentObject(AppState.shared)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)), "popover-done.png", dir)
    }

    private static func panel(_ session: LiveSession, _ controller: LivePanelController,
                              width: CGFloat?, height: CGFloat? = nil) -> some View {
        LivePanelView()
            .environmentObject(session)
            .environmentObject(controller)
            .frame(width: width, height: height)
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private static func snap(_ view: some View, _ name: String, _ dir: URL) async {
        let host = NSHostingView(rootView: AnyView(view.environment(\.controlActiveState, .key)))
        var size = host.fittingSize
        size.width = max(size.width, 200)
        size.height = min(max(size.height, 60), 1400)
        host.frame = NSRect(origin: .zero, size: size)
        let window = KeyableWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFront(nil)
        try? await Task.sleep(nanoseconds: 600_000_000)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name))
        }
        window.orderOut(nil)
    }
}
