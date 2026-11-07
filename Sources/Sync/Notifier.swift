import Foundation
import UserNotifications

/// Local notifications: sync problems, and the weekly "re-install from Xcode" reminder.
enum Notifier {
    private static let expiryID = "signing-expiry"
    private static let expiryEveID = "signing-expiry-eve"

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notify(title: String, body: String, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Signing expiry

    /// When this build stops opening. Apps signed with a free Apple ID get a provisioning
    /// profile valid for 7 days; its expiration date is inside the app bundle.
    static var signingExpiry: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let keyRange = text.range(of: "<key>ExpirationDate</key>"),
              let open = text.range(of: "<date>", range: keyRange.upperBound..<text.endIndex),
              let close = text.range(of: "</date>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return ISO8601DateFormatter().date(from: String(text[open.upperBound..<close.lowerBound]))
    }

    /// Schedules reminders the evening before and a few hours before the build expires.
    static func scheduleExpiryReminders(enabled: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [expiryID, expiryEveID])
        guard enabled, let expiry = signingExpiry else { return }

        let reminders: [(String, Date, String)] = [
            (expiryEveID, expiry.addingTimeInterval(-24 * 3600),
             "StepsBridge יפסיק להיפתח מחר. חבר את האייפון ל‑Mac ולחץ ▶️ ב‑Xcode כדי לחדש."),
            (expiryID, expiry.addingTimeInterval(-3 * 3600),
             "StepsBridge יפסיק להיפתח בעוד כ‑3 שעות. חבר את האייפון ל‑Mac ולחץ ▶️ ב‑Xcode."),
        ]
        for (id, date, body) in reminders where date > Date() {
            let content = UNMutableNotificationContent()
            content.title = "צריך לחדש את StepsBridge"
            content.body = body
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}
