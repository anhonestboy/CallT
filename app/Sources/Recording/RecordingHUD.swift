import SwiftUI
import AppKit

/// Piccolo pannello galleggiante in alto a destra mentre si registra:
/// puntino rosso pulsante, timer, pulsante stop.
@MainActor
final class RecordingHUD {
    static let shared = RecordingHUD()
    private var panel: NSPanel?

    func show() {
        guard panel == nil else { return }
        let host = NSHostingView(rootView: HUDView())
        host.frame = NSRect(x: 0, y: 0, width: 168, height: 40)
        let panel = NSPanel(
            contentRect: host.frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false)
        panel.contentView = host
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - host.frame.width - 16,
                y: frame.maxY - host.frame.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct HUDView: View {
    @ObservedObject private var recorder = CallRecorder.shared
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(elapsedString)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary)
            }
            Button {
                Task { await recorder.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Stop and transcribe"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .onAppear { pulse = true }
    }

    private var elapsedString: String {
        guard let started = recorder.startedAt else { return "0:00" }
        let s = Int(Date().timeIntervalSince(started))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
