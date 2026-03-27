import UserNotifications

class NotificationManager {
    private var lastNotificationTime: Date = .distantPast
    private let cooldown: TimeInterval = 5 // avoid notification spam

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(title: String, body: String) {
        guard Date().timeIntervalSince(lastNotificationTime) > cooldown else { return }
        lastNotificationTime = Date()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
