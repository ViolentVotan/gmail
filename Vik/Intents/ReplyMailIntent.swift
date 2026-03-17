import AppIntents

@AppIntent(schema: .mail.replyMail)
struct ReplyMailIntent {
    static let openAppWhenRun = true

    @Parameter var target: MailMessageEntity
    @Parameter var to: [IntentPerson]
    @Parameter var cc: [IntentPerson]
    @Parameter var bcc: [IntentPerson]
    @Parameter var subject: String?
    @Parameter var body: AttributedString?
    @Parameter var attachments: [IntentFile]
    @Parameter var account: MailAccountEntity?
    @Parameter var isReplyAll: Bool

    func perform() async throws -> some IntentResult {
        let messageId = target.id
        let accountID = await IntentHelpers.findOwnerAccount(for: messageId)
            ?? account?.id
            ?? ""
        await MainActor.run {
            var userInfo: [String: Any] = [
                "messageId": messageId,
                "replyAll": isReplyAll,
            ]
            if !accountID.isEmpty {
                userInfo["accountID"] = accountID
            }
            NotificationCenter.default.post(
                name: .replyEmailFromIntent,
                object: nil,
                userInfo: userInfo
            )
        }
        return .result()
    }
}
