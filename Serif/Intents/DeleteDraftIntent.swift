import AppIntents

@AppIntent(schema: .mail.deleteDraft)
struct DeleteDraftIntent {
    static let openAppWhenRun = false

    @Parameter var entities: [MailDraftEntity]

    func perform() async throws -> some IntentResult {
        for draft in entities {
            let accountID = draft.account.id
            guard !accountID.isEmpty else {
                throw IntentError.accountNotFound
            }
            try await GmailDraftService.shared.deleteDraft(draftID: draft.id, accountID: accountID)
        }
        return .result()
    }
}
