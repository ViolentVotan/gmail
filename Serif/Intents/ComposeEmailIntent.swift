import AppIntents

@AppIntent(schema: .mail.createDraft)
struct ComposeEmailIntent {
    static let openAppWhenRun = true

    @Parameter var to: [IntentPerson]
    @Parameter var cc: [IntentPerson]
    @Parameter var subject: String?
    @Parameter var body: AttributedString?
    @Parameter var account: MailAccountEntity?

    func perform() async throws -> some IntentResult & ReturnsValue<MailMessageEntity> {
        let recipient: String? = to.first.flatMap { person in
            guard let handle = person.handle else { return nil }
            switch handle.value {
            case .emailAddress(let email): return email
            case .applicationDefined(let value): return value
            default: return nil
            }
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .composeEmailFromIntent,
                object: nil,
                userInfo: recipient.map { ["recipient": $0] } ?? [:]
            )
        }
        return .result(value: MailMessageEntity())
    }
}
