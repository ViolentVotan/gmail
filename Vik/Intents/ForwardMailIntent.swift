import AppIntents

@AppIntent(schema: .mail.forwardMail)
struct ForwardMailIntent {
    static let openAppWhenRun = true

    @Parameter var target: MailMessageEntity
    @Parameter var to: [IntentPerson]
    @Parameter var cc: [IntentPerson]
    @Parameter var bcc: [IntentPerson]
    @Parameter var subject: String?
    @Parameter var body: AttributedString?
    @Parameter var attachments: [IntentFile]
    @Parameter var account: MailAccountEntity?

    func perform() async throws -> some IntentResult {
        let messageId = target.id
        let accountID = await IntentHelpers.findOwnerAccount(for: messageId)
            ?? account?.id
            ?? ""
        let recipient = to.first.flatMap { person -> String? in
            guard let handle = person.handle else { return nil }
            switch handle.value {
            case .emailAddress(let email): return email
            case .applicationDefined(let value): return value
            default: return nil
            }
        }
        await MainActor.run {
            var userInfo: [String: Any] = ["messageId": messageId]
            if !accountID.isEmpty {
                userInfo["accountID"] = accountID
            }
            if let recipient, !recipient.isEmpty {
                userInfo["to"] = recipient
            }
            NotificationCenter.default.post(
                name: .forwardEmailFromIntent,
                object: nil,
                userInfo: userInfo
            )
        }
        return .result()
    }
}
