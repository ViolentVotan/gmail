import AppIntents

struct OpenEmailIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Email"
    static let description: IntentDescription = "Opens a specific email in Serif"
    static let openAppWhenRun = true

    @Parameter(title: "Email")
    var email: EmailEntity

    func perform() async throws -> some IntentResult {
        let messageId = email.id
        let accountID = await findOwnerAccount(for: messageId) ?? ""
        await MainActor.run {
            var userInfo: [String: String] = ["messageId": messageId]
            if !accountID.isEmpty {
                userInfo["accountID"] = accountID
            }
            NotificationCenter.default.post(
                name: .openEmailFromIntent,
                object: nil,
                userInfo: userInfo
            )
        }
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

