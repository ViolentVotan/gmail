import AppIntents

@AppIntent(schema: .mail.deleteMail)
struct TrashEmailIntent {
    static let openAppWhenRun = false

    @Parameter var entities: [MailMessageEntity]

    func perform() async throws -> some IntentResult {
        for message in entities {
            let messageId = message.id
            guard let accountID = await IntentHelpers.findOwnerAccount(for: messageId) else {
                throw IntentError.accountNotFound
            }
            try await GmailMessageService.shared.trashMessage(id: messageId, accountID: accountID)
        }
        return .result()
    }
}
