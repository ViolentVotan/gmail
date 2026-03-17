import AppIntents

@AppIntent(schema: .mail.archiveMail)
struct ArchiveEmailIntent {
    static let openAppWhenRun = false

    @Parameter var entities: [MailMessageEntity]

    func perform() async throws -> some IntentResult {
        for message in entities {
            let messageId = message.id
            guard let accountID = await IntentHelpers.findOwnerAccount(for: messageId) else {
                throw IntentError.accountNotFound
            }
            try await GmailMessageService.shared.archiveMessage(id: messageId, accountID: accountID)
        }
        return .result()
    }
}
