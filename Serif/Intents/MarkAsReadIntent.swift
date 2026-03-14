import AppIntents

struct MarkAsReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Email as Read"
    static let description: IntentDescription = "Marks an email as read in Serif"
    static let openAppWhenRun = false

    @Parameter(title: "Email")
    var email: EmailEntity

    func perform() async throws -> some IntentResult {
        let messageId = email.id
        // Find which account owns this message by scanning databases
        guard let accountID = await findOwnerAccount(for: messageId) else {
            throw MarkAsReadError.accountNotFound
        }
        try await GmailMessageService.shared.markAsRead(id: messageId, accountID: accountID)
        return .result()
    }

    private func findOwnerAccount(for messageId: String) async -> String? {
        let accounts = await MainActor.run { AccountStore.shared.accounts }
        for account in accounts {
            guard let db = try? MailDatabase.shared(for: account.id) else { continue }
            let exists = try? await db.dbPool.read { database in
                try MailDatabaseQueries.messageExists(messageId, in: database)
            }
            if exists == true {
                return account.id
            }
        }
        return nil
    }
}

enum MarkAsReadError: Error, LocalizedError {
    case accountNotFound

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "Could not find the account that owns this email"
        }
    }
}
