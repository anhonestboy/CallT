import SwiftUI
import AVFoundation
import UserNotifications

/// Stato e richiesta dei permessi di sistema (schermo, microfono, notifiche).
@MainActor
final class PermissionsModel: ObservableObject {
    @Published var screenGranted = false
    @Published var micStatus: AVAuthorizationStatus = .notDetermined
    @Published var notificationsStatus: UNAuthorizationStatus = .notDetermined

    func refresh() {
        screenGranted = CGPreflightScreenCaptureAccess()
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                self.notificationsStatus = status
            }
        }
    }

    func requestScreen() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refresh() }
        }
    }
}

/// Righe di stato permessi, usate in Impostazioni e nell'onboarding.
struct PermissionsRows: View {
    @ObservedObject var model: PermissionsModel

    var body: some View {
        row(granted: model.screenGranted,
            title: String(localized: "Screen & system audio recording"),
            detail: String(localized: "Needed to record calls (any call app)."),
            action: String(localized: "Enable…")) {
            model.requestScreen()
        }
        row(granted: model.micStatus == .authorized,
            title: String(localized: "Microphone"),
            detail: String(localized: "Needed to record your voice."),
            action: model.micStatus == .notDetermined
                ? String(localized: "Allow…")
                : String(localized: "Open Settings…")) {
            if model.micStatus == .notDetermined {
                model.requestMic()
            } else {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
        row(granted: model.notificationsStatus == .authorized,
            title: String(localized: "Notifications"),
            detail: String(localized: "One notification when each call is ready."),
            action: String(localized: "Allow…")) {
            model.requestNotifications()
        }
    }

    private func row(
        granted: Bool, title: String, detail: String,
        action: String, onAction: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(action, action: onAction)
            }
        }
    }
}
