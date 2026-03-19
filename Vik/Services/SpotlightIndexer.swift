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
    private let indexedIDsKey = "SpotlightIndexedIDs"
    private var persistTask: Task<Void, Never>?

    private init() {
        indexedIDs = UserDefaults.standard.stringArray(forKey: indexedIDsKey) ?? []
        cleanLegacyItemsIfNeeded()
    }

    func indexEmail(_ email: Email) async {
        guard let messageID = email.gmailMessageID else { return }

        // Deduplicate: if already indexed, refresh LRU position and return early
        if let existingIndex = indexedIDs.firstIndex(of: messageID) {
            indexedIDs.remove(at: existingIndex)
            indexedIDs.append(messageID)
            schedulePersist()
            return
        }

        // Clean up legacy CSSearchableItem entries on first run after migration
        cleanLegacyItemsIfNeeded()

        let entity = MailMessageEntity(from: email)

        if indexedIDs.count >= maxIndexed {
            let evictCount = max(1, Int(Double(maxIndexed) * evictionFraction))
            let toEvict = Array(indexedIDs.prefix(evictCount))
            try? await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: toEvict)
            indexedIDs.removeFirst(evictCount)
            schedulePersist()
        }

        try? await CSSearchableIndex.default().indexAppEntities([entity])
        indexedIDs.append(messageID)
        schedulePersist()
    }

    /// Removes all Spotlight items and resets the indexed ID tracking.
    func deleteAllItems() async {
        try? await CSSearchableIndex.default().deleteAllSearchableItems()
        indexedIDs.removeAll()
        persistIndexedIDs()
    }

    // MARK: - Legacy migration

    private func cleanLegacyItemsIfNeeded() {
        guard !legacyCleaned else { return }
        Task {
            // Remove legacy items indexed as CSSearchableItem with domain "com.vikingz.vik.emails"
            try? await CSSearchableIndex.default().deleteSearchableItems(
                withDomainIdentifiers: ["com.vikingz.vik.emails"]
            )
            await MainActor.run { legacyCleaned = true }
        }
    }

    // MARK: - Private

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.persistIndexedIDs()
        }
    }

    private func persistIndexedIDs() {
        UserDefaults.standard.set(indexedIDs, forKey: indexedIDsKey)
    }
}
