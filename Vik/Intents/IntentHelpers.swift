import AppIntents
import Foundation

enum IntentHelpers {
    /// Scans all account databases to find which account owns a given Gmail message ID.
    static func findOwnerAccount(for messageId: String) async -> String? {
        let accounts = await MainActor.run { AccountStore.shared.accounts }
        for account in accounts {
            guard let db = try? await MailDatabase.shared(for: account.id) else { continue }
            let exists = try? await db.dbPool.read { database in
                try MailDatabaseQueries.messageExists(messageId, in: database)
            }
            if exists == true {
                return account.id
            }
        }
        return nil
    }

    /// Extracts an email address string from an `IntentPerson` handle.
    static func emailAddress(from person: IntentPerson) -> String? {
        guard let handle = person.handle else { return nil }
        switch handle.value {
        case .emailAddress(let email): return email
        case .applicationDefined(let value): return value
        default: return nil
        }
    }

    /// Iterates over a collection of mail message entities, resolves each owner account,
    /// and invokes `action` for each (messageId, accountID) pair.
    static func performOnEach(
        _ entities: [MailMessageEntity],
        action: (_ messageId: String, _ accountID: String) async throws -> Void
    ) async throws {
        for entity in entities {
            guard let accountID = await findOwnerAccount(for: entity.id) else {
                throw IntentError.accountNotFound
            }
            try await action(entity.id, accountID)
        }
    }
}
