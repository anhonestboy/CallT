import Foundation
import UserNotifications

/// Notifiche di sistema a fine elaborazione. Se l'autorizzazione manca o
/// fallisce (es. bundle non firmato correttamente), degrada in silenzio.
enum Notifier {
    static func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard AppSettings.notifyOnComplete else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { appLog("⚠️ Notifica non inviata: \(error.localizedDescription)") }
        }
    }
}
