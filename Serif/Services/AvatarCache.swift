import AppKit

/// Disk-backed image cache with a 90-day TTL.
/// An empty on-disk file = "no image" (negative cache) to avoid re-fetching 404s.
final class AvatarCache {
    static let shared = AvatarCache()
    private init() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private let ttl: TimeInterval = 90 * 24 * 60 * 60 // 90 days

    private let cacheDir: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.serif.avatars")

    func image(for urlString: String) async -> NSImage? {
        let fileURL = cacheDir.appendingPathComponent(cacheKey(for: urlString))

        // Serve from disk if still fresh
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < ttl {
            // Empty file = cached negative (404 / no image)
            guard let size = attrs[.size] as? Int, size > 0 else { return nil }
            // NSImage(contentsOfFile:) supports SVG + bitmaps; better than NSImage(data:) for SVG
            return NSImage(contentsOfFile: fileURL.path)
        }

        // Fetch from network
        guard let url = URL(string: urlString),
              let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200, !data.isEmpty else {
            try? Data().write(to: fileURL) // cache negative
            return nil
        }

        try? data.write(to: fileURL)
        return NSImage(contentsOfFile: fileURL.path)
    }

    private func cacheKey(for urlString: String) -> String {
        var hash: UInt64 = 5381
        for byte in urlString.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return "\(hash)"
    }
}
