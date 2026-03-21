import AppIntents

@AppIntent(schema: .mail.archiveMail)
struct ArchiveEmailIntent {
    static let openAppWhenRun = false

    @Parameter var entities: [MailMessageEntity]

    func perform() async throws -> some IntentResult {
        try await IntentHelpers.performOnEach(entities) { messageId, accountID in
            try await GmailMessageService.shared.archiveMessage(id: messageId, accountID: accountID)
        }
        return .result()
    }
}
