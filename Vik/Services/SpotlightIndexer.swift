import AppIntents
import CoreSpotlight

actor SpotlightIndexer {
    static let shared = SpotlightIndexer()
    /// Set for O(1) membership testing; array tracks insertion order (oldest first) for eviction.
    private var indexedIDSet: Set<String> = []
    private var indexedIDOrder: [String] = []
    private let maxIndexed = 1000
    /// Fraction of oldest entries to evict when the threshold is reached.
    private let evictionFraction = 0.25
    private var legacyCleaned = false
    private let indexedIDsKey = "SpotlightIndexedIDs"
    private var persistTask: Task<Void, Never>?

    private init() {
        let persisted = UserDefaults.standard.stringArray(forKey: indexedIDsKey) ?? []
        indexedIDOrder = persisted
        indexedIDSet = Set(persisted)
    }

    func indexEmail(_ email: Email) async {
        guard let messageID = email.gmailMessageID else { return }

        // Deduplicate: if already indexed, just refresh — no O(n) scan needed.
        if indexedIDSet.contains(messageID) {
            // Re-index to pick up any metadata changes; order stays, no eviction needed.
            let entity = MailMessageEntity(from: email)
            try? await CSSearchableIndex.default().indexAppEntities([entity])
            return
        }

        // Clean up legacy CSSearchableItem entries on first run after migration
        cleanLegacyItemsIfNeeded()

        let entity = MailMessageEntity(from: email)

        if indexedIDSet.count >= maxIndexed {
            let evictCount = max(1, Int(Double(maxIndexed) * evictionFraction))
            let toEvict = Array(indexedIDOrder.prefix(evictCount))
            try? await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: toEvict)
            indexedIDOrder.removeFirst(evictCount)
            for id in toEvict { indexedIDSet.remove(id) }
            schedulePersist()
        }

        try? await CSSearchableIndex.default().indexAppEntities([entity])
        indexedIDSet.insert(messageID)
        indexedIDOrder.append(messageID)
        schedulePersist()
    }

    /// Removes all Spotlight items and resets the indexed ID tracking.
    func deleteAllItems() async {
        try? await CSSearchableIndex.default().deleteAllSearchableItems()
        indexedIDSet.removeAll()
        indexedIDOrder.removeAll()
        persistIndexedIDs()
    }

    // MARK: - Legacy migration

    private func cleanLegacyItemsIfNeeded() {
        guard !legacyCleaned else { return }
        legacyCleaned = true
        Task {
            try? await CSSearchableIndex.default().deleteSearchableItems(
                withDomainIdentifiers: ["com.vikingz.vik.emails"]
            )
        }
    }

    // MARK: - Private

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.persistIndexedIDs()
        }
    }

    private func persistIndexedIDs() {
        UserDefaults.standard.set(indexedIDOrder, forKey: indexedIDsKey)
    }
}
