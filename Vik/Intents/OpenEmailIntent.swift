import AppIntents

struct OpenEmailIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Email"
    static let description: IntentDescription = "Opens a specific email in Vik"
    static let openAppWhenRun = true

    @Parameter(title: "Email")
    var email: MailMessageEntity

    func perform() async throws -> some IntentResult {
        let messageId = email.id
        let accountID = await IntentHelpers.findOwnerAccount(for: messageId) ?? ""
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
}
