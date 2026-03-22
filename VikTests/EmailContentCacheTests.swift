import Testing
@testable import Vik

@Suite struct EmailContentCacheTests {
    private func makeContent() -> EmailContentCache.ThreadContent {
        EmailContentCache.ThreadContent(
            messages: [],
            htmlParts: [:],
            trackerResult: nil,
            resolvedMessageHTML: [:]
        )
    }

    @Test func getReturnsNilForMissingKey() {
        let cache = EmailContentCache()
        #expect(cache.get("nonexistent") == nil)
    }

    @Test func setAndGetRoundTrips() {
        let cache = EmailContentCache()
        cache.set("thread1", content: makeContent())
        #expect(cache.get("thread1") != nil)
    }

    @Test func invalidateRemovesEntry() {
        let cache = EmailContentCache()
        cache.set("thread1", content: makeContent())
        cache.invalidate("thread1")
        #expect(cache.get("thread1") == nil)
    }

    @Test func clearRemovesAllEntries() {
        let cache = EmailContentCache()
        cache.set("a", content: makeContent())
        cache.set("b", content: makeContent())
        cache.clear()
        #expect(cache.get("a") == nil)
        #expect(cache.get("b") == nil)
    }

    @Test func evictsLRUWhenOverCapacity() {
        let cache = EmailContentCache(maxEntries: 3)
        cache.set("a", content: makeContent())
        cache.set("b", content: makeContent())
        cache.set("c", content: makeContent())
        _ = cache.get("a")  // touch "a" — makes it recently used
        cache.set("d", content: makeContent())  // should evict "b"
        #expect(cache.get("a") != nil)
        #expect(cache.get("b") == nil)  // evicted (LRU)
        #expect(cache.get("c") != nil)
        #expect(cache.get("d") != nil)
    }

    @Test func updateMutatesExistingEntry() {
        let cache = EmailContentCache()
        cache.set("thread1", content: makeContent())
        cache.update("thread1") { $0.resolvedMessageHTML["msg1"] = "<p>resolved</p>" }
        let updated = cache.get("thread1")
        #expect(updated?.resolvedMessageHTML["msg1"] == "<p>resolved</p>")
    }

    @Test func updateNoopsForMissingKey() {
        let cache = EmailContentCache()
        cache.update("missing") { $0.resolvedMessageHTML["x"] = "y" }
        #expect(cache.get("missing") == nil)
    }
}
