import AppIntents

@AppIntent(schema: .mail.updateMail)
struct UpdateMailIntent {
    static let openAppWhenRun = false

    @Parameter var target: [MailMessageEntity]
    @Parameter var isRead: Bool?
    @Parameter var isJunk: Bool?
    @Parameter var isFlagged: Bool?
    @Parameter var mailbox: MailboxEntity?

    func perform() async throws -> some IntentResult {
        for message in target {
            let messageId = message.id
            guard let accountID = await IntentHelpers.findOwnerAccount(for: messageId) else {
                throw IntentError.accountNotFound
            }

            if let isRead {
                if isRead {
                    try await GmailMessageService.shared.markAsRead(id: messageId, accountID: accountID)
                } else {
                    try await GmailMessageService.shared.markAsUnread(id: messageId, accountID: accountID)
                }
            }

            if let isFlagged {
                try await GmailMessageService.shared.setStarred(isFlagged, id: messageId, accountID: accountID)
            }

            if let isJunk {
                if isJunk {
                    try await GmailMessageService.shared.spamMessage(id: messageId, accountID: accountID)
                } else {
                    try await GmailMessageService.shared.modifyLabels(
                        id: messageId,
                        add: [GmailSystemLabel.inbox],
                        remove: [GmailSystemLabel.spam],
                        accountID: accountID
                    )
                }
            }

            if let mailbox {
                let targetLabelID = mailbox.id
                switch targetLabelID {
                case GmailSystemLabel.inbox:
                    try await GmailMessageService.shared.modifyLabels(
                        id: messageId,
                        add: [GmailSystemLabel.inbox],
                        remove: [GmailSystemLabel.trash, GmailSystemLabel.spam],
                        accountID: accountID
                    )
                case GmailSystemLabel.trash:
                    try await GmailMessageService.shared.modifyLabels(
                        id: messageId,
                        add: [GmailSystemLabel.trash],
                        remove: [GmailSystemLabel.inbox],
                        accountID: accountID
                    )
                case GmailSystemLabel.spam:
                    try await GmailMessageService.shared.modifyLabels(
                        id: messageId,
                        add: [GmailSystemLabel.spam],
                        remove: [GmailSystemLabel.inbox],
                        accountID: accountID
                    )
                default:
                    // Archive (remove from inbox) or move to any other label
                    try await GmailMessageService.shared.modifyLabels(
                        id: messageId,
                        add: targetLabelID == GmailSystemLabel.starred ? [GmailSystemLabel.starred] : [targetLabelID],
                        remove: [GmailSystemLabel.inbox],
                        accountID: accountID
                    )
                }
            }
        }
        return .result()
    }
}

// MARK: - Intent Error

enum IntentError: Error, LocalizedError {
    case accountNotFound

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            "Could not find the account that owns this email"
        }
    }
}
