import Foundation
private import os

// MARK: - Encryption constants

private enum FileStoreKeychain {
    static let service: String = {
        #if DEBUG
        "com.vikingz.vik.filestore.debug"
        #else
        "com.vikingz.vik.filestore"
        #endif
    }()
    static let account = "encryption-key"
}

/// Cached coders shared by all `PerAccountFileStore` specializations
/// (static let not allowed on generic types).
private enum PerAccountFileStoreCoders {
    nonisolated static let encoder = JSONEncoder()
    nonisolated static let decoder = JSONDecoder()
}

/// Generic per-account JSON file persistence.
///
/// Handles the boilerplate shared by `SnoozeStore`, `ScheduledSendStore`, and
/// `OfflineActionQueue`: a `[String: [Item]]` dictionary backed by one JSON
/// file per account under Application Support.
@Observable
@MainActor
final class PerAccountFileStore<Item: Codable & Identifiable & Sendable> {

    nonisolated private static var logger: Logger {
        Logger(category: "PerAccountFileStore")
    }

    /// Per-account storage keyed by accountID.
    private(set) var itemsByAccount: [String: [Item]] = [:]

    /// Flat view of all items across all accounts.
    var allItems: [Item] {
        itemsByAccount.values.flatMap { $0 }
    }

    /// Total count of items across all accounts without flattening the dictionary.
    /// Prefer this over `allItems.count` for badge/count-only reads.
    var totalCount: Int {
        itemsByAccount.values.reduce(0) { $0 + $1.count }
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

    @ObservationIgnored private let decoder = JSONDecoder()

    @concurrent private static func decodeFromDisk(
        url: URL,
        decoder: JSONDecoder,
        legacyDecoder: (@Sendable (Data) -> [Item]?)?
    ) async -> [Item]? {
        guard let raw = try? Data(contentsOf: url) else { return nil }

        // Try decrypting first (new format). Fall back to treating `raw` as
        // plain JSON to handle files written before encryption was introduced.
        let data: Data
        if let decrypted = try? DataEncryption.decrypt(
            raw,
            service: FileStoreKeychain.service,
            account: FileStoreKeychain.account
        ) {
            data = decrypted
        } else {
            data = raw
        }

        if let decoded = try? decoder.decode([Item].self, from: data) {
            return decoded
        } else if let decoded = legacyDecoder?(data) {
            return decoded
        } else {
            logger.warning("Failed to decode \(url.lastPathComponent, privacy: .public)")
            return nil
        }
    }

    /// Loads items from disk, atomically replacing any in-memory data for the
    /// given account.
    func load(accountID: String) async {
        if let decoded = await Self.decodeFromDisk(
            url: fileURL(accountID),
            decoder: decoder,
            legacyDecoder: legacyDecoder
        ) {
            itemsByAccount[accountID] = decoded
        }
    }

    /// Loads items from disk, merging with existing in-memory items rather than
    /// replacing. Deduplicates by `Item.ID`.
    func loadMerging(accountID: String) async {
        guard let decoded = await Self.decodeFromDisk(
            url: fileURL(accountID),
            decoder: decoder,
            legacyDecoder: legacyDecoder
        ) else { return }
        let existingIDs = Set((itemsByAccount[accountID] ?? []).map { $0.id })
        let newItems = decoded.filter { !existingIDs.contains($0.id) }
        itemsByAccount[accountID, default: []].append(contentsOf: newItems)
    }

    func save(accountID: String) {
        let items = itemsByAccount[accountID] ?? []
        let url = fileURL(accountID)
        saveTasks[accountID]?.cancel()
        saveTasks[accountID] = Task {
            await Self.writeToDisk(items: items, url: url)
        }
    }

    /// Writes items for the given account to disk immediately, without coalescing.
    /// Cancels any pending coalesced save first to avoid a stale write racing the flush.
    /// Use this for critical stores where losing a queued item on crash is unacceptable.
    func saveAndWait(accountID: String) async {
        saveTasks[accountID]?.cancel()
        saveTasks[accountID] = nil
        guard let items = itemsByAccount[accountID] else { return }
        let url = fileURL(accountID)
        await Self.writeToDisk(items: items, url: url)
    }

    /// Appends an item and immediately flushes to disk without coalescing.
    /// Use for critical stores (e.g. offline queues) where losing a queued item on crash
    /// is unacceptable.
    func appendAndWait(_ item: Item, accountID: String) async {
        itemsByAccount[accountID, default: []].append(item)
        await saveAndWait(accountID: accountID)
    }

    @concurrent private static func writeToDisk(items: [Item], url: URL) async {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let plaintext  = try PerAccountFileStoreCoders.encoder.encode(items)
            let ciphertext = try DataEncryption.encrypt(
                plaintext,
                service: FileStoreKeychain.service,
                account: FileStoreKeychain.account
            )
            try ciphertext.write(to: url, options: .atomic)
        } catch {
            logger.error("Save failed: \(error, privacy: .public)")
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
    func loadFiltered(by accountID: String, keyPath: KeyPath<Item, String>) async {
        await load(accountID: accountID)
        let items = itemsByAccount[accountID] ?? []
        let filtered = items.filter { $0[keyPath: keyPath] == accountID }
        if filtered.count != items.count {
            replaceItems(filtered, accountID: accountID)
        }
    }

    // MARK: - Targeted Accessors

    /// Find first item matching predicate without materializing the full flattened array.
    func firstItem(where predicate: (Item) -> Bool) -> Item? {
        for items in itemsByAccount.values {
            if let match = items.first(where: predicate) {
                return match
            }
        }
        return nil
    }

    /// Filter items matching predicate, iterating per-account without flattening.
    func filteredItems(where predicate: (Item) -> Bool) -> [Item] {
        var result: [Item] = []
        for items in itemsByAccount.values {
            result.append(contentsOf: items.filter(predicate))
        }
        return result
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
