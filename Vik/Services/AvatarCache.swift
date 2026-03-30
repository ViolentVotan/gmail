import AppKit

/// Disk-backed image cache with a 90-day TTL.
/// An empty on-disk file = "no image" (negative cache) to avoid re-fetching 404s.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()
    private var directoryCreated = false
    private init() {
        memoryCache.countLimit = 200
        negativeCacheKeys.countLimit = 500
    }

    private func ensureCacheDirectory() {
        guard !directoryCreated else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        directoryCreated = true
    }

    private let ttl: TimeInterval = 90 * 24 * 60 * 60 // 90 days

    /// In-memory LRU cache to avoid repeated disk reads on scroll.
    private let memoryCache = NSCache<NSString, NSImage>()
    /// Tracks negative lookups in memory (URLs that returned 404 / no image).
    private let negativeCacheKeys = NSCache<NSString, NSNull>()
    private let cacheDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #if DEBUG
        return caches.appendingPathComponent("com.vikingz.vik.avatars-debug")
        #else
        return caches.appendingPathComponent("com.vikingz.vik.avatars")
        #endif
    }()

    /// Keys currently being fetched from network (prevents duplicate requests).
    private var inFlightKeys: Set<String> = []
    /// Continuations waiting for an in-flight fetch to complete.
    private var waiters: [String: [CheckedContinuation<NSImage?, Never>]] = [:]

    /// Concurrency throttling — prevents 50+ simultaneous network requests when
    /// scrolling through a large email list. Mirrors ThumbnailCache's pattern.
    private var activeFetches = 0
    private let maxConcurrentFetches = 6
    private var pendingQueue: [(key: String, url: URL, fileURL: URL)] = []

    func image(for urlString: String) async -> NSImage? {
        ensureCacheDirectory()
        let key = cacheKey(for: urlString) as NSString

        // 1. In-memory hit
        if let cached = memoryCache.object(forKey: key) { return cached }
        if negativeCacheKeys.object(forKey: key) != nil { return nil }

        let fileURL = cacheDir.appendingPathComponent(key as String)

        // 2. Serve from disk if still fresh (read performed off the main actor)
        switch await Self.readFromDisk(fileURL: fileURL, ttl: ttl) {
        case .fresh(let img):
            memoryCache.setObject(img, forKey: key)
            return img
        case .negative:
            negativeCacheKeys.setObject(NSNull(), forKey: key)
            return nil
        case .miss:
            break
        }

        // 3. Coalesce with in-flight request if one exists
        let keyString = key as String
        if inFlightKeys.contains(keyString) {
            return await withCheckedContinuation { continuation in
                waiters[keyString, default: []].append(continuation)
            }
        }

        // 4. Fetch from network (throttled)
        guard let url = URL(string: urlString) else { return nil }

        inFlightKeys.insert(keyString)

        if activeFetches >= maxConcurrentFetches {
            // Queue the request and wait for it to be dequeued
            return await withCheckedContinuation { continuation in
                pendingQueue.append((key: keyString, url: url, fileURL: fileURL))
                waiters[keyString, default: []].append(continuation)
            }
        }

        activeFetches += 1
        return await performFetch(keyString: keyString, url: url, fileURL: fileURL)
    }

    private func performFetch(keyString: String, url: URL, fileURL: URL) async -> NSImage? {
        let key = keyString as NSString
        let result = await fetchAndCache(url: url, fileURL: fileURL)
        if let img = result {
            memoryCache.setObject(img, forKey: key)
        } else {
            negativeCacheKeys.setObject(NSNull(), forKey: key)
        }

        // Resume all waiters with the result
        inFlightKeys.remove(keyString)
        let pending = waiters.removeValue(forKey: keyString) ?? []
        for continuation in pending {
            continuation.resume(returning: result)
        }

        activeFetches = max(0, activeFetches - 1)
        dequeueNext()

        return result
    }

    private func dequeueNext() {
        while activeFetches < maxConcurrentFetches, !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            // If all waiters for this key were already resolved by a concurrent fetch, skip it.
            guard let pending = waiters[next.key], !pending.isEmpty else {
                inFlightKeys.remove(next.key)
                continue
            }
            // Reserve the slot before yielding to the Task to prevent over-scheduling.
            activeFetches += 1
            Task {
                _ = await performFetch(keyString: next.key, url: next.url, fileURL: next.fileURL)
            }
            break
        }
    }

    private enum DiskReadResult {
        case fresh(NSImage)
        case negative   // file exists but is empty (cached 404)
        case miss       // file absent or stale
    }

    @concurrent private static func readFromDisk(fileURL: URL, ttl: TimeInterval) async -> DiskReadResult {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < ttl else { return .miss }
        guard let size = attrs[.size] as? Int, size > 0 else { return .negative }
        guard let img = NSImage(contentsOfFile: fileURL.path) else { return .miss }
        return .fresh(img)
    }

    @concurrent private func fetchAndCache(url: URL, fileURL: URL) async -> NSImage? {
        guard let (data, response) = try? await NetworkConfig.externalSession.data(from: url) else { return nil }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200, !data.isEmpty else {
            try? Data().write(to: fileURL, options: .atomic) // cache negative on disk
            return nil
        }

        let image = NSImage(data: data)
        try? data.write(to: fileURL, options: .atomic)
        return image
    }

    /// Remove all cached avatar images from disk.
    func clearAll() {
        memoryCache.removeAllObjects()
        negativeCacheKeys.removeAllObjects()
        inFlightKeys.removeAll()
        pendingQueue.removeAll()
        activeFetches = 0
        // Resume any pending waiters with nil before clearing
        for (_, continuations) in waiters {
            for continuation in continuations {
                continuation.resume(returning: nil)
            }
        }
        waiters.removeAll()
        let dir = cacheDir
        Task.detached {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func cacheKey(for urlString: String) -> String {
        String(stableHash(urlString))
    }
}
