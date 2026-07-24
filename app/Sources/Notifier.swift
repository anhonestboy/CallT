import Foundation
import AppKit
import UserNotifications

/// Notifiche di sistema con azioni rapide (Apri note / Apri trascrizione).
/// Se l'autorizzazione manca, degrada in silenzio.
enum Notifier {
    private static let categoryID = "com.werootbox.callt.job"

    static func setup() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let openNotes = UNNotificationAction(
            identifier: "openNotes", title: String(localized: "Open notes"))
        let openTranscript = UNNotificationAction(
            identifier: "openTranscript", title: String(localized: "Open transcript"))
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [openNotes, openTranscript],
            intentIdentifiers: [])
        center.setNotificationCategories([category])
        center.delegate = NotificationDelegate.shared
    }

    static func notify(title: String, body: String) {
        notifyDone(title: title, body: body, transcript: nil, notes: nil)
    }

    static func notifyDone(title: String, body: String, transcript: URL?, notes: URL?) {
        guard AppSettings.notifyOnComplete else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if transcript != nil || notes != nil {
            content.categoryIdentifier = categoryID
            var info: [String: String] = [:]
            if let transcript { info["transcript"] = transcript.path }
            if let notes { info["notes"] = notes.path }
            content.userInfo = info
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { appLog("⚠️ Notification not delivered: \(error.localizedDescription)") }
        }
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    // Mostra il banner anche quando l'app è in primo piano.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let transcript = (info["transcript"] as? String).map { URL(fileURLWithPath: $0) }
        let notes = (info["notes"] as? String).map { URL(fileURLWithPath: $0) }
        let target: URL?
        switch response.actionIdentifier {
        case "openTranscript": target = transcript
        case "openNotes": target = notes
        default: target = notes ?? transcript  // tap sulla notifica
        }
        if let target, FileManager.default.fileExists(atPath: target.path) {
            DispatchQueue.main.async { NSWorkspace.shared.open(target) }
        }
        completionHandler()
    }
}
