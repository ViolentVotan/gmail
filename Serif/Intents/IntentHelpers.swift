import Foundation

enum IntentHelpers {
    /// Scans all account databases to find which account owns a given Gmail message ID.
    static func findOwnerAccount(for messageId: String) async -> String? {
        let accounts = await MainActor.run { AccountStore.shared.accounts }
        for account in accounts {
            guard let db = try? MailDatabase.shared(for: account.id) else { continue }
            let exists = try? await db.dbPool.read { database in
                try MailDatabaseQueries.messageExists(messageId, in: database)
            }
            if exists == true {
                return account.id
            }
        }
        return nil
    }
}
