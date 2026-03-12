import AppIntents

struct SearchEmailIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Email"
    static let description: IntentDescription = "Searches emails in Serif"
    static let openAppWhenRun = true

    @Parameter(title: "Query")
    var query: String

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .searchEmailFromIntent,
                object: nil,
                userInfo: ["query": query]
            )
        }
        return .result()
    }
}

