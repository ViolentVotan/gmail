import AppKit
import Foundation
import UserNotifications
private import os

enum EmailNotificationPriority: Sendable {
    case urgent    // Has deadline or sender flagged as important
    case normal    // Regular email
    case low       // FYI-only, newsletters, marketing
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "NotificationService")
    private override init() { super.init() }

    private var badgeTask: Task<Void, Never>?

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
                Self.logger.warning("Notification permission not granted")
            }
        }
    }

    func notifyNewEmail(
        messageId: String,
        threadId: String,
        senderName: String,
        subject: String,
        snippet: String,
        accountID: String,
        priority: EmailNotificationPriority = .normal
    ) {
        guard UserDefaults.standard.bool(forKey: UserDefaultsKey.notificationsEnabled) else { return }

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

        // Apple Intelligence uses interruption level to determine notification
        // summarization priority and whether to surface in notification stacks.
        switch priority {
        case .urgent:
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 0.9
        case .normal:
            content.interruptionLevel = .active
            content.relevanceScore = 0.5
        case .low:
            content.interruptionLevel = .passive
            content.relevanceScore = 0.1
        }

        let request = UNNotificationRequest(
            identifier: messageId,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        // Play sound only when app is in foreground (system notifications handle background sound)
        if NSApplication.shared.isActive {
            SoundManager.play(.newMail)
        }
        badgeTask?.cancel()
        badgeTask = Task { await MailboxViewModel.updateDockBadge() }
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
            // Validate account still exists before executing actions
            guard AccountStore.shared.accounts.contains(where: { $0.id == accountID }) else {
                Self.logger.warning("Notification action for removed account \(accountID, privacy: .private) — ignoring")
                return
            }

            switch actionIdentifier {
            case "ARCHIVE":
                Task {
                    do {
                        try await GmailMessageService.shared.archiveMessage(id: messageId, accountID: accountID)
                    } catch {
                        OfflineActionQueue.shared.enqueue(
                            OfflineAction(actionType: .archive, messageIds: [messageId], accountID: accountID)
                        )
                    }
                }
            case "MARK_READ":
                Task {
                    do {
                        try await GmailMessageService.shared.markAsRead(id: messageId, accountID: accountID)
                    } catch {
                        OfflineActionQueue.shared.enqueue(
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
    static let replyEmailFromIntent       = Notification.Name("replyEmailFromIntent")
    static let forwardEmailFromIntent     = Notification.Name("forwardEmailFromIntent")
}
