import AppIntents

struct MarkAsReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Email as Read"
    static let description: IntentDescription = "Marks an email as read in Serif"
    static let openAppWhenRun = false

    @Parameter(title: "Email")
    var email: EmailEntity

    func perform() async throws -> some IntentResult {
        let messageId = email.id
        guard let accountID = await IntentHelpers.findOwnerAccount(for: messageId) else {
            throw MarkAsReadError.accountNotFound
        }
        try await GmailMessageService.shared.markAsRead(id: messageId, accountID: accountID)
        return .result()
    }
}

enum MarkAsReadError: Error, LocalizedError {
    case accountNotFound

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "Could not find the account that owns this email"
        }
    }
}
