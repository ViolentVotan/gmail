import AppIntents

struct ComposeEmailIntent: AppIntent {
    static let title: LocalizedStringResource = "Compose Email"
    static let description: IntentDescription = "Opens a new compose window in Serif"
    static let openAppWhenRun = true

    @Parameter(title: "Recipient", default: nil)
    var recipient: String?

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .composeEmailFromIntent,
                object: nil,
                userInfo: recipient.map { ["recipient": $0] } ?? [:]
            )
        }
        return .result()
    }
}

