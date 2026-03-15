import Foundation

/// A simple LRU (Least Recently Used) cache with configurable size and eviction fraction.
/// All access must be from `@MainActor` — no internal locking needed.
@MainActor
final class LRUCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var accessOrder: [Key] = []
    private let maxSize: Int
    private let evictionFraction: Double

    init(maxSize: Int, evictionFraction: Double = 0.25) {
        self.maxSize = maxSize
        self.evictionFraction = evictionFraction
    }

    subscript(key: Key) -> Value? {
        get {
            guard let value = storage[key] else { return nil }
            touchKey(key)
            return value
        }
        set {
            if let value = newValue {
                storage[key] = value
                touchKey(key)
                evictIfNeeded()
            } else {
                storage.removeValue(forKey: key)
                accessOrder.removeAll { $0 == key }
            }
        }
    }

    var count: Int { storage.count }

    func removeAll() {
        storage.removeAll()
        accessOrder.removeAll()
    }

    private func touchKey(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func evictIfNeeded() {
        guard storage.count > maxSize else { return }
        let evictCount = max(1, Int(Double(maxSize) * evictionFraction))
        let keysToRemove = Array(accessOrder.prefix(evictCount))
        for key in keysToRemove {
            storage.removeValue(forKey: key)
        }
        accessOrder.removeFirst(min(evictCount, accessOrder.count))
    }
}
