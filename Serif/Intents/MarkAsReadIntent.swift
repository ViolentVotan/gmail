import AppIntents

@AppIntent(schema: .mail.updateMail)
struct UpdateMailIntent {
    static let openAppWhenRun = false

    @Parameter var target: [MailMessageEntity]
    @Parameter var isRead: Bool?
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
