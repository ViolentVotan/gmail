import AppIntents

@AppIntent(schema: .mail.sendDraft)
struct SendDraftIntent {
    static let openAppWhenRun = false

    @Parameter var target: MailDraftEntity
    @Parameter var sendLaterDate: Date?

    func perform() async throws -> some IntentResult {
        let accountID = target.account.id
        guard !accountID.isEmpty else {
            throw IntentError.accountNotFound
        }
        try await GmailDraftService.shared.sendDraft(draftId: target.id, accountID: accountID)
        return .result()
    }
}
