import SwiftUI

@main
struct CallTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared
    @StateObject private var recorder = CallRecorder.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(state)
        } label: {
            // Stesso glifo dell'icona app; varianti per registrazione/elaborazione.
            Image(systemName: recorder.isRecording
                ? "record.circle"
                : (state.currentJob == nil ? "waveform" : "waveform.badge.microphone"))
                .symbolEffect(.pulse, isActive: recorder.isRecording || state.currentJob != nil)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ScreenshotRenderer.runIfRequested() { return }
        AppState.shared.onLaunch()
        Onboarding.showIfNeeded()
        // Debug: rigenera le note da una trascrizione esistente.
        if let idx = CommandLine.arguments.firstIndex(of: "--regen-notes"),
           CommandLine.arguments.count > idx + 1 {
            let path = CommandLine.arguments[idx + 1]
            AppState.shared.regenerateNotes(transcriptPath: path)
        }
        // Debug: ritenta un file specifico ignorando il registro.
        if let idx = CommandLine.arguments.firstIndex(of: "--process"),
           CommandLine.arguments.count > idx + 1 {
            AppState.shared.enqueue(URL(fileURLWithPath: CommandLine.arguments[idx + 1]), force: true)
        }
        // Flag di collaudo: registra qualche secondo e ferma da solo.
        if CommandLine.arguments.contains("--test-record-audio") {
            Task { @MainActor in
                await CallRecorder.shared.start(mode: .audioOnly)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await CallRecorder.shared.stop()
            }
        }
        if CommandLine.arguments.contains("--test-record-video") {
            Task { @MainActor in
                await CallRecorder.shared.start(mode: .videoAudio)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await CallRecorder.shared.stop()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Lo stato del monitoraggio resta in UserDefaults: se era attivo,
        // riparte al prossimo avvio senza toccare la preferenza.
    }
}
