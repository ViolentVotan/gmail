import AppIntents
import CoreSpotlight

@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    /// Tracks indexed message IDs in insertion order (oldest first) for LRU eviction.
    private var indexedIDs: [String] = []
    private let maxIndexed = 1000
    /// Fraction of oldest entries to evict when the threshold is reached.
    private let evictionFraction = 0.25
    private var legacyCleaned = false

    private init() {
        cleanLegacyItemsIfNeeded()
    }

    func indexEmail(_ email: Email) async {
        guard let messageID = email.gmailMessageID else { return }

        // Clean up legacy CSSearchableItem entries on first run after migration
        cleanLegacyItemsIfNeeded()

        let entity = MailMessageEntity(from: email)

        if indexedIDs.count >= maxIndexed {
            let evictCount = max(1, Int(Double(maxIndexed) * evictionFraction))
            let toEvict = Array(indexedIDs.prefix(evictCount))
            try? await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: toEvict)
            indexedIDs.removeFirst(evictCount)
        }

        try? await CSSearchableIndex.default().indexAppEntities([entity])
        indexedIDs.append(messageID)
    }

    // MARK: - Legacy migration

    private func cleanLegacyItemsIfNeeded() {
        guard !legacyCleaned else { return }
        legacyCleaned = true
        Task {
            // Remove legacy items indexed as CSSearchableItem with domain "com.vikingz.vik.emails"
            try? await CSSearchableIndex.default().deleteSearchableItems(
                withDomainIdentifiers: ["com.vikingz.vik.emails"]
            )
        }
    }
}
