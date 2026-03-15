import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    private override init() { super.init() }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY", title: "Reply",
            textInputButtonTitle: "Send", textInputPlaceholder: "Type reply..."
        )
        let archiveAction = UNNotificationAction(identifier: "ARCHIVE", title: "Archive")
        let markReadAction = UNNotificationAction(identifier: "MARK_READ", title: "Mark Read")

        let emailCategory = UNNotificationCategory(
            identifier: "NEW_EMAIL",
            actions: [replyAction, archiveAction, markReadAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([emailCategory])

        Task {
            let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted != true {
                print("[NotificationService] Permission not granted")
            }
        }
    }

    func notifyNewEmail(
        messageId: String,
        threadId: String,
        senderName: String,
        subject: String,
        snippet: String,
        accountID: String
    ) {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }

        let content = UNMutableNotificationContent()
        content.title = senderName
        content.subtitle = subject
        content.body = String(snippet.prefix(100))
        content.categoryIdentifier = "NEW_EMAIL"
        content.threadIdentifier = threadId
        content.userInfo = [
            "messageId": messageId,
            "threadId": threadId,
            "accountID": accountID
        ]

        let request = UNNotificationRequest(
            identifier: messageId,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Capture all needed data from the response before crossing isolation boundaries,
        // since UNNotificationResponse may not be Sendable.
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText

        guard let messageId = userInfo["messageId"] as? String,
              let accountID = userInfo["accountID"] as? String else { return }

        await MainActor.run {
            switch actionIdentifier {
            case "ARCHIVE":
                Task {
                    do {
                        try await GmailMessageService.shared.archiveMessage(id: messageId, accountID: accountID)
                    } catch {
                        await OfflineActionQueue.shared.enqueue(
                            OfflineAction(actionType: .archive, messageIds: [messageId], accountID: accountID)
                        )
                    }
                }
            case "MARK_READ":
                Task {
                    do {
                        try await GmailMessageService.shared.markAsRead(id: messageId, accountID: accountID)
                    } catch {
                        await OfflineActionQueue.shared.enqueue(
                            OfflineAction(actionType: .markRead, messageIds: [messageId], accountID: accountID)
                        )
                    }
                }
            case "REPLY":
                if let text = replyText {
                    NotificationCenter.default.post(
                        name: .quickReplyFromNotification,
                        object: nil,
                        userInfo: ["messageId": messageId, "text": text, "accountID": accountID]
                    )
                }
            default:
                NotificationCenter.default.post(
                    name: .openEmailFromIntent,
                    object: nil,
                    userInfo: ["messageId": messageId, "accountID": accountID]
                )
            }
        }
    }
}

extension Notification.Name {
    static let quickReplyFromNotification = Notification.Name("quickReplyFromNotification")
    static let openEmailFromIntent        = Notification.Name("openEmailFromIntent")
    static let composeEmailFromIntent     = Notification.Name("composeEmailFromIntent")
    static let searchEmailFromIntent      = Notification.Name("searchEmailFromIntent")
}
