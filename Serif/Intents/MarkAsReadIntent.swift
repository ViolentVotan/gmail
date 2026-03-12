import AppIntents

struct MarkAsReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Email as Read"
    static let description: IntentDescription = "Marks an email as read in Serif"
    static let openAppWhenRun = false

    @Parameter(title: "Email")
    var email: EmailEntity

    func perform() async throws -> some IntentResult {
        let messageId = email.id
        // Find which account owns this message by scanning caches
        let accountID: String? = await MainActor.run {
            for account in AccountStore.shared.accounts {
                let key = MailCacheStore.folderKey(labelIDs: ["INBOX"], query: nil)
                let cache = MailCacheStore.shared.loadFolderCache(accountID: account.id, folderKey: key)
                if cache.messages.contains(where: { $0.id == messageId }) {
                    return account.id
                }
            }
            return nil
        }
        if let accountID {
            await MainActor.run {
                Task {
                    try? await GmailMessageService.shared.markAsRead(id: messageId, accountID: accountID)
                }
            }
        }
        return .result()
    }
}
