import Foundation

/// Generic per-account JSON file persistence.
///
/// Handles the boilerplate shared by `SnoozeStore`, `ScheduledSendStore`, and
/// `OfflineActionQueue`: a `[String: [Item]]` dictionary backed by one JSON
/// file per account under Application Support.
@Observable
@MainActor
final class PerAccountFileStore<Item: Codable & Identifiable & Sendable> {

    /// Per-account storage keyed by accountID.
    private(set) var itemsByAccount: [String: [Item]] = [:]

    /// Flat view of all items across all accounts.
    var allItems: [Item] {
        itemsByAccount.values.flatMap { $0 }
    }

    private let fileURL: @Sendable (String) -> URL
    /// Optional fallback decoder for migrating from legacy wrapper formats
    /// (e.g. `SnoozeFileContents`, `OfflineQueueFileContents`).
    /// On successful legacy decode the next `save` writes the new bare-array format.
    private let legacyDecoder: (@Sendable (Data) -> [Item]?)?

    /// Creates a store whose files live at the URL returned by `fileURL`.
    ///
    /// - Parameters:
    ///   - fileURL: Maps an `accountID` to the on-disk JSON file path.
    ///   - legacyDecoder: Optional closure that extracts `[Item]` from a legacy
    ///     wrapper format. Called only when the primary `[Item]` decode fails.
    init(
        fileURL: @escaping @Sendable (String) -> URL,
        legacyDecoder: (@Sendable (Data) -> [Item]?)? = nil
    ) {
        self.fileURL = fileURL
        self.legacyDecoder = legacyDecoder
    }

    // MARK: - Persistence

    /// Loads items from disk, atomically replacing any in-memory data for the
    /// given account.
    func load(accountID: String) {
        let url = fileURL(accountID)
        guard let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            itemsByAccount[accountID] = decoded
        } else if let decoded = legacyDecoder?(data) {
            itemsByAccount[accountID] = decoded
        }
    }

    /// Loads items from disk, merging with existing in-memory items rather than
    /// replacing. Deduplicates by `Item.ID`.
    func loadMerging(accountID: String) {
        let url = fileURL(accountID)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoded: [Item]
        if let primary = try? JSONDecoder().decode([Item].self, from: data) {
            decoded = primary
        } else if let legacy = legacyDecoder?(data) {
            decoded = legacy
        } else {
            return
        }
        let existingIDs = Set(
            (itemsByAccount[accountID] ?? []).map { $0.id }
        )
        let newItems = decoded.filter { !existingIDs.contains($0.id) }
        itemsByAccount[accountID, default: []].append(contentsOf: newItems)
    }

    func save(accountID: String) {
        let url = fileURL(accountID)
        let items = itemsByAccount[accountID] ?? []
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(items).write(to: url, options: .atomic)
    }

    /// Removes all in-memory data and the on-disk JSON file for the given account.
    func deleteAccount(_ accountID: String) {
        itemsByAccount.removeValue(forKey: accountID)
        let url = fileURL(accountID)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - In-Memory Mutations

    func append(_ item: Item, accountID: String) {
        itemsByAccount[accountID, default: []].append(item)
    }

    func removeAll(accountID: String, where predicate: (Item) -> Bool) {
        itemsByAccount[accountID]?.removeAll(where: predicate)
    }

    func replaceItems(_ items: [Item], accountID: String) {
        itemsByAccount[accountID] = items
    }
}
