import Foundation
private import os

/// Generic per-account JSON file persistence.
///
/// Handles the boilerplate shared by `SnoozeStore`, `ScheduledSendStore`, and
/// `OfflineActionQueue`: a `[String: [Item]]` dictionary backed by one JSON
/// file per account under Application Support.
@Observable
@MainActor
final class PerAccountFileStore<Item: Codable & Identifiable & Sendable> {

    nonisolated private static var logger: Logger {
        Logger(subsystem: "com.vikingz.vik", category: "PerAccountFileStore")
    }

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

    /// Tracks the latest pending write task per account. Cancels the previous task before
    /// scheduling a new one so only the most recent state is written (coalescing saves).
    private var saveTasks: [String: Task<Void, Never>] = [:]

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
        } else {
            Self.logger.warning("Failed to decode \(url.lastPathComponent, privacy: .public) for \(accountID, privacy: .public)")
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
            Self.logger.warning("Failed to decode \(url.lastPathComponent, privacy: .public) for \(accountID, privacy: .public)")
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
        saveTasks[accountID]?.cancel()
        saveTasks[accountID] = Task {
            guard !Task.isCancelled else { return }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(items).write(to: url, options: .atomic)
            } catch {
                Self.logger.error("Save failed for \(accountID, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Removes all in-memory data and the on-disk JSON file for the given account.
    func deleteAccount(_ accountID: String) {
        itemsByAccount.removeValue(forKey: accountID)
        let url = fileURL(accountID)
        try? FileManager.default.removeItem(at: url)
    }

    /// Loads items from disk and filters by account ID using the given key path,
    /// pruning mismatched items (legacy safety). Shared by SnoozeStore and ScheduledSendStore.
    func loadFiltered(by accountID: String, keyPath: KeyPath<Item, String>) {
        load(accountID: accountID)
        let items = itemsByAccount[accountID] ?? []
        let filtered = items.filter { $0[keyPath: keyPath] == accountID }
        if filtered.count != items.count {
            replaceItems(filtered, accountID: accountID)
        }
    }

    // MARK: - In-Memory Mutations

    func append(_ item: Item, accountID: String) {
        itemsByAccount[accountID, default: []].append(item)
        save(accountID: accountID)
    }

    func removeAll(accountID: String, where predicate: (Item) -> Bool) {
        itemsByAccount[accountID]?.removeAll(where: predicate)
        save(accountID: accountID)
    }

    func replaceItems(_ items: [Item], accountID: String) {
        itemsByAccount[accountID] = items
        save(accountID: accountID)
    }
}
