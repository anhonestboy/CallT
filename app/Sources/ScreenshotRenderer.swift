import SwiftUI
import AppKit

/// Hidden tool: `CallT --render-screenshots <dir>` renders the real UI
/// offscreen into PNGs for the README, then exits. Keeps repo screenshots
/// authentic and reproducible on every release.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
enum ScreenshotRenderer {
    static func runIfRequested() -> Bool {
        guard let idx = CommandLine.arguments.firstIndex(of: "--render-screenshots"),
              CommandLine.arguments.count > idx + 1 else { return false }
        let dir = URL(fileURLWithPath: CommandLine.arguments[idx + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            await renderAll(into: dir)
            exit(0)
        }
        return true
    }

    private static func renderAll(into dir: URL) async {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let state = AppState.shared
        await snap(GeneralTab().environmentObject(state).frame(width: 580),
                   name: "settings-general.png", into: dir, settle: 2.5)
        await snap(ProcessingTab().frame(width: 580),
                   name: "settings-processing.png", into: dir, settle: 1.0)
        await snap(NotesTab().frame(width: 580),
                   name: "settings-notes.png", into: dir, settle: 1.0)
        await snap(AutomationTab().frame(width: 580),
                   name: "settings-automation.png", into: dir, settle: 3.0)
        state.startMonitoring()
        await snap(menuMock(state: state), name: "menu.png", into: dir, settle: 1.0)
        await snap(banner(), name: "banner.png", into: dir, settle: 0.5)
    }

    /// Illustrative rendering of the menu content, styled like a menu.
    private static func menuMock(state: AppState) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            MenuContent()
        }
        .environmentObject(state)
        .buttonStyle(.plain)
        .frame(width: 240, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(16)
    }

    private static func banner() -> some View {
        let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        let icon = iconURL.flatMap { NSImage(contentsOf: $0) }
        return HStack(spacing: 28) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 148, height: 148)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "CallT")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                Text(verbatim: "Record · Transcribe · Summarize — on-device")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(44)
        .frame(width: 900)
    }

    private static func snap(
        _ view: some View, name: String, into dir: URL, settle: Double
    ) async {
        let host = NSHostingView(rootView: AnyView(
            view.tint(.blue).environment(\.controlActiveState, .key)))
        var size = host.fittingSize
        size.width = max(size.width, 200)
        size.height = min(max(size.height, 120), 1400)
        host.frame = NSRect(origin: .zero, size: size)

        let window = KeyableWindow(
            contentRect: host.frame,
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))  // fuori schermo
        window.makeKeyAndOrderFront(nil)  // key: i controlli si disegnano attivi

        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        // Re-fit after async content (language lists, shortcuts) has loaded.
        var fitted = host.fittingSize
        fitted.width = max(fitted.width, size.width)
        fitted.height = min(max(fitted.height, 120), 1400)
        host.frame = NSRect(origin: .zero, size: fitted)
        window.setContentSize(fitted)
        window.makeKey()  // il focus può essere passato a snap successivi
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name))
        }
        window.orderOut(nil)
    }
}
