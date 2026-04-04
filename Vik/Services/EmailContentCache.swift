import Synchronization

/// Thread-safe LRU cache for preprocessed thread content.
/// Uses Mutex (not @MainActor) so the prefetcher can read/write from @concurrent contexts
/// without hopping to the main thread.
final class EmailContentCache: Sendable {
    static let shared = EmailContentCache()

    struct ThreadContent: Sendable {
        var messages: [GmailMessage]
        var htmlParts: [String: PrecomputedMessageHTML]
        var trackerResult: TrackerResult?
        var resolvedMessageHTML: [String: String]
    }

    private struct Storage {
        var entries: [String: ThreadContent] = [:]
        var accessOrder: [String] = []  // most recent at end; O(n) firstIndex acceptable at maxEntries=50 — consider SendableLRUCache if limit grows
        let maxEntries: Int
    }

    private let storage: Mutex<Storage>

    init(maxEntries: Int = 50) {
        storage = Mutex(Storage(maxEntries: maxEntries))
    }

    func get(_ threadID: String) -> ThreadContent? {
        storage.withLock { s in
            guard s.entries[threadID] != nil else { return nil }
            if let idx = s.accessOrder.firstIndex(of: threadID) {
                s.accessOrder.remove(at: idx)
            }
            s.accessOrder.append(threadID)
            return s.entries[threadID]
        }
    }

    func set(_ threadID: String, content: ThreadContent) {
        storage.withLock { s in
            s.entries[threadID] = content
            if let idx = s.accessOrder.firstIndex(of: threadID) {
                s.accessOrder.remove(at: idx)
            }
            s.accessOrder.append(threadID)
            while s.entries.count > s.maxEntries, let oldest = s.accessOrder.first {
                s.accessOrder.removeFirst()
                s.entries.removeValue(forKey: oldest)
            }
        }
    }

    func update(_ threadID: String, mutate: @Sendable (inout ThreadContent) -> Void) {
        storage.withLock { s in
            guard var content = s.entries[threadID] else { return }
            mutate(&content)
            s.entries[threadID] = content
        }
    }

    func invalidate(_ threadID: String) {
        storage.withLock { s in
            s.entries.removeValue(forKey: threadID)
            s.accessOrder.removeAll { $0 == threadID }
        }
    }

    func clear() {
        storage.withLock { s in
            s.entries.removeAll()
            s.accessOrder.removeAll()
        }
    }
}
