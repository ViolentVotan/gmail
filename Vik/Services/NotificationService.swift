import AppKit
import Foundation
import UserNotifications
private import GRDB
private import os

enum EmailNotificationPriority: Sendable {
    case urgent    // Has deadline or sender flagged as important
    case normal    // Regular email
    case low       // FYI-only, newsletters, marketing
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    nonisolated private static let logger = Logger(category: "NotificationService")
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

        let joinAction = UNNotificationAction(identifier: "JOIN_MEETING", title: "Join Meeting", options: [.foreground])
        let snoozeAction = UNNotificationAction(identifier: "SNOOZE_5MIN", title: "Snooze 5 min")
        let calendarCategory = UNNotificationCategory(
            identifier: "CALENDAR_REMINDER",
            actions: [joinAction, snoozeAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([emailCategory, calendarCategory])

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
        badgeTask = Task { await NotificationService.updateDockBadge() }
    }

    /// Sums inbox unread counts across all accounts and updates the dock badge.
    static func updateDockBadge() async {
        let accounts = AccountStore.shared.accounts
        let total = await Task.detached {
            var sum = 0
            for account in accounts {
                guard !Task.isCancelled else { break }
                do {
                    let db = try await MailDatabase.shared(for: account.id)
                    let count = try await db.dbPool.read { database in
                        try MailDatabaseQueries.unreadCount(forLabel: GmailSystemLabel.inbox, in: database)
                    }
                    sum += count
                } catch {
                    logger.error("updateDockBadge: DB error for \(account.id): \(error)")
                }
            }
            return sum
        }.value
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }

    // MARK: - Calendar Notifications

    /// Removes stale calendar reminder notifications and schedules fresh ones for upcoming events.
    func scheduleCalendarReminders(events: [CalendarEvent]) async {
        guard UserDefaults.standard.bool(forKey: UserDefaultsKey.notificationsEnabled) else { return }

        let center = UNUserNotificationCenter.current()
        let now = Date()

        // Remove all previously scheduled calendar reminders before scheduling new ones.
        let requests = await center.pendingNotificationRequests()
        let staleIds = requests
            .map(\.identifier)
            .filter { $0.hasPrefix("calendar-") }
        center.removePendingNotificationRequests(withIdentifiers: staleIds)

        for event in events {
            guard !event.reminders.isEmpty else { continue }

            for reminder in event.reminders {
                let fireDate = event.startTime.addingTimeInterval(TimeInterval(-reminder.minutes * 60))
                guard fireDate > now else { continue }

                let content = UNMutableNotificationContent()
                content.title = event.summary
                var bodyParts = [event.startTime.formattedTime]
                if let location = event.location { bodyParts.append(location) }
                content.body = bodyParts.joined(separator: " · ")
                content.categoryIdentifier = "CALENDAR_REMINDER"
                content.userInfo = [
                    "eventId": event.googleEventId,
                    "calendarId": event.calendarId,
                    "accountID": event.accountID,
                    "conferenceLink": event.conferenceLink?.absoluteString ?? ""
                ]

                let interval = fireDate.timeIntervalSinceNow
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                let identifier = "calendar-\(event.googleEventId)-\(reminder.minutes)"
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
    }

    /// Loads upcoming events from the database and reschedules all calendar reminder notifications.
    /// Call this from `CalendarSyncEngine` after each sync completes.
    func refreshCalendarReminders(db: MailDatabase, accountID: String) async {
        guard UserDefaults.standard.bool(forKey: UserDefaultsKey.notificationsEnabled) else { return }

        do {
            let now = Date()
            let windowEnd = now.addingTimeInterval(7 * 86400) // look-ahead: 7 days

            let records = try await db.dbPool.read { database in
                // Fetch all visible calendar IDs for this account, then query upcoming events.
                let calendars = try MailDatabaseQueries.visibleCalendars(accountId: accountID, in: database)
                let calendarIds = calendars.map(\.calendarId)
                guard !calendarIds.isEmpty else { return [CalendarEventRecord]() }
                return try MailDatabaseQueries.eventsForDateRange(
                    accountId: accountID,
                    calendarIds: calendarIds,
                    start: now.timeIntervalSince1970,
                    end: windowEnd.timeIntervalSince1970,
                    in: database
                )
            }

            // Convert records to domain events (no attendees needed for notifications).
            let events = records.map { $0.toCalendarEvent(attendees: [], calendarColor: .blue) }
            await scheduleCalendarReminders(events: events)
        } catch {
            Self.logger.error("Failed to refresh calendar reminders: \(String(describing: error))")
        }
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
        let requestIdentifier = response.notification.request.identifier
        let requestContent = response.notification.request.content

        // Handle calendar reminder actions separately — they have no messageId.
        if requestContent.categoryIdentifier == "CALENDAR_REMINDER" {
            guard userInfo["accountID"] is String else { return }
            switch actionIdentifier {
            case "JOIN_MEETING":
                if let linkString = userInfo["conferenceLink"] as? String,
                   !linkString.isEmpty,
                   let url = URL(string: linkString) {
                    _ = await MainActor.run { NSWorkspace.shared.open(url) }
                }
            case "SNOOZE_5MIN":
                let snoozedContent = requestContent.mutableCopy() as! UNMutableNotificationContent
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5 * 60, repeats: false)
                let snoozedId = requestIdentifier + "-snoozed"
                let request = UNNotificationRequest(identifier: snoozedId, content: snoozedContent, trigger: trigger)
                try? await center.add(request)
            default:
                // Default tap — no-op for calendar notifications (could open calendar view in future).
                break
            }
            return
        }

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
                // Unstructured Task: bridges MainActor sync context → async API call.
                // Idempotent — OfflineActionQueue deduplicates on replay.
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
                // Unstructured Task: bridges MainActor sync context → async API call.
                // Idempotent — OfflineActionQueue deduplicates on replay.
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
    static let replyEmailFromIntent       = Notification.Name("replyEmailFromIntent")
    static let forwardEmailFromIntent     = Notification.Name("forwardEmailFromIntent")
}
