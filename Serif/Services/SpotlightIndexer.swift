import AppIntents
import CoreSpotlight

@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    private var indexedCount = 0
    private let maxIndexed = 1000
    private var legacyCleaned = false

    private init() {
        cleanLegacyItemsIfNeeded()
    }

    func indexEmail(_ email: Email) async {
        guard let messageID = email.gmailMessageID else { return }

        // Clean up legacy CSSearchableItem entries on first run after migration
        cleanLegacyItemsIfNeeded()

        let entity = EmailEntity(
            id: messageID,
            subject: email.subject,
            senderName: email.sender.name,
            date: email.date
        )

        try? await CSSearchableIndex.default().indexAppEntities([entity])

        indexedCount += 1
        if indexedCount > maxIndexed {
            try? await CSSearchableIndex.default().deleteAllSearchableItems()
            indexedCount = 0
        }
    }

    // MARK: - Legacy migration

    private func cleanLegacyItemsIfNeeded() {
        guard !legacyCleaned else { return }
        legacyCleaned = true
        Task {
            // Remove legacy items indexed as CSSearchableItem with domain "com.vikingz.serif.emails"
            try? await CSSearchableIndex.default().deleteSearchableItems(
                withDomainIdentifiers: ["com.vikingz.serif.emails"]
            )
        }
    }
}
