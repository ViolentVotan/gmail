import Foundation

/// A simple LRU (Least Recently Used) cache with configurable size and eviction fraction.
/// All access must be from `@MainActor` — no internal locking needed.
///
/// Uses a doubly-linked list + dictionary for O(1) get, set, and eviction.
@MainActor
final class LRUCache<Key: Hashable, Value> {
    /// Doubly-linked list node. Sentinels use nil key/value.
    private final class Node {
        var key: Key?
        var value: Value?
        var prev: Node?
        var next: Node?

        /// Sentinel initializer (no key/value).
        init() {}

        /// Data node initializer.
        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    /// Maps keys to their linked-list nodes for O(1) lookup.
    private var storage: [Key: Node] = [:]

    /// Sentinel head/tail nodes simplify insert/remove logic (no nil checks).
    private let head = Node()
    private let tail = Node()

    private let maxSize: Int
    private let evictionFraction: Double

    init(maxSize: Int, evictionFraction: Double = 0.25) {
        self.maxSize = maxSize
        self.evictionFraction = evictionFraction
        head.next = tail
        tail.prev = head
    }

    subscript(key: Key) -> Value? {
        get {
            guard let node = storage[key] else { return nil }
            moveToTail(node)
            return node.value
        }
        set {
            if let value = newValue {
                if let node = storage[key] {
                    node.value = value
                    moveToTail(node)
                } else {
                    let node = Node(key: key, value: value)
                    storage[key] = node
                    appendBeforeTail(node)
                }
                evictIfNeeded()
            } else {
                if let node = storage.removeValue(forKey: key) {
                    removeNode(node)
                }
            }
        }
    }

    var count: Int { storage.count }

    func removeAll() {
        storage.removeAll()
        head.next = tail
        tail.prev = head
    }

    // MARK: - Linked list operations (all O(1))

    /// Detaches a node from its current position.
    private func removeNode(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        node.prev = nil
        node.next = nil
    }

    /// Inserts a node just before the tail sentinel (most-recently-used position).
    private func appendBeforeTail(_ node: Node) {
        let prev = tail.prev!
        prev.next = node
        node.prev = prev
        node.next = tail
        tail.prev = node
    }

    /// Moves an existing node to the most-recently-used position (O(1)).
    private func moveToTail(_ node: Node) {
        removeNode(node)
        appendBeforeTail(node)
    }

    /// Evicts the least-recently-used entries (from head side) when over capacity.
    private func evictIfNeeded() {
        guard storage.count > maxSize else { return }
        let overflow = storage.count - maxSize
        let batchSize = max(1, Int(Double(maxSize) * evictionFraction))
        let evictCount = min(storage.count, max(overflow, batchSize))
        for _ in 0..<evictCount {
            guard let lru = head.next, lru !== tail, let key = lru.key else { break }
            removeNode(lru)
            storage.removeValue(forKey: key)
        }
    }
}
