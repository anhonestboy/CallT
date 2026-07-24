import SwiftUI
import AppKit

/// Finestra di benvenuto al primo avvio: cartella, permessi, motore note.
@MainActor
enum Onboarding {
    private static var window: NSWindow?

    static func showIfNeeded() {
        guard !AppSettings.defaults.bool(forKey: "onboardingDone") else { return }
        show()
    }

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingView(rootView: OnboardingView {
            AppSettings.defaults.set(true, forKey: "onboardingDone")
            window?.close()
            window = nil
        })
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 430)
        let w = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.contentView = host
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

private struct OnboardingView: View {
    let finish: () -> Void
    @State private var step = 0
    @StateObject private var permissions = PermissionsModel()
    @AppStorage(SettingsKey.watchFolder) private var watchFolder = ""

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            Divider()
            HStack {
                if step > 0 {
                    Button(String(localized: "Back")) { withAnimation { step -= 1 } }
                }
                Spacer()
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Button(step == 2 ? String(localized: "Start using CallT") : String(localized: "Continue")) {
                    if step == 2 {
                        AppState.shared.startMonitoring()
                        finish()
                    } else {
                        withAnimation { step += 1 }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 430)
        .onAppear { permissions.refresh() }
        .onChange(of: step) { _, _ in permissions.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            VStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 84, height: 84)
                }
                Text(verbatim: "CallT")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Record, transcribe and summarize your calls — on-device.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recordings folder").font(.callout.weight(.medium))
                        Text("Every video or audio file that lands here gets transcribed automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "Choose…")) { pickFolder() }
                }
                Text(verbatim: (watchFolder as NSString).abbreviatingWithTildeInPath)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
        case 1:
            VStack(alignment: .leading, spacing: 16) {
                Text("Permissions")
                    .font(.title2.weight(.semibold))
                Text("CallT works entirely on your Mac. To record calls it needs these permissions — you can also grant them later, when you first hit Record.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 14) {
                    PermissionsRows(model: permissions)
                }
                .padding(14)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                Spacer()
            }
        default:
            VStack(alignment: .leading, spacing: 16) {
                Text("Call notes")
                    .font(.title2.weight(.semibold))
                Text("After each transcription CallT writes organized Markdown notes: summary, topics, decisions, action items — with speakers identified. By default it uses Apple Intelligence on-device (free, private). You can switch to Claude, OpenRouter, DeepSeek or Ollama in Settings → Notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(String(localized: "Record from the menu bar icon or with ⌥⌘R"), systemImage: "record.circle")
                    .font(.callout)
                Label(String(localized: "Drop files on the menu bar panel to transcribe them"), systemImage: "arrow.down.doc")
                    .font(.callout)
                Spacer()
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            watchFolder = url.path
        }
    }
}
