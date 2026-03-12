import AppIntents

struct OpenEmailIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Email"
    static let description: IntentDescription = "Opens a specific email in Serif"
    static let openAppWhenRun = true

    @Parameter(title: "Email")
    var email: EmailEntity

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .openEmailFromIntent,
                object: nil,
                userInfo: ["messageId": email.id]
            )
        }
        return .result()
    }
}

