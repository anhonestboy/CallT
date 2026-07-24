import SwiftUI

@main
struct CallTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared
    @StateObject private var recorder = CallRecorder.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            // Stesso glifo dell'icona app; varianti per registrazione/elaborazione.
            Image(systemName: recorder.isRecording
                ? "record.circle"
                : (state.currentJob == nil ? "waveform" : "waveform.badge.microphone"))
        }

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
