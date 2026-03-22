import Foundation

actor TemporaryFileManager {
    static let shared = TemporaryFileManager()
    private init() {}

    private static let baseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Vik-Attachments", isDirectory: true)

    /// Cache of written temp files: [attachmentID: URL]
    private var cache: [String: URL] = [:]

    // MARK: - Write

    /// Writes data to a temp file. Returns URL. Reuses cached file if it exists.
    func tempFile(for attachmentID: String, messageID: String, filename: String, data: Data) throws -> URL {
        if let cached = cache[attachmentID],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        // Sanitize messageID to prevent path traversal in directory construction.
        let safeMessageID = messageID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        guard !safeMessageID.isEmpty, safeMessageID != ".", safeMessageID != ".." else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        // Sanitize filename to prevent path traversal.
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let dir = Self.baseDirectory.appendingPathComponent(safeMessageID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent(safeName)
        try data.write(to: url)
        cache[attachmentID] = url
        return url
    }

    // MARK: - Lookup

    /// Returns cached URL if temp file exists for this attachment, nil otherwise.
    func cachedURL(for attachmentID: String) -> URL? {
        guard let url = cache[attachmentID],
              FileManager.default.fileExists(atPath: url.path) else {
            cache[attachmentID] = nil
            return nil
        }
        return url
    }

    // MARK: - Cleanup

    /// Cleans up temp files older than 1 hour.
    func cleanupStale() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)

        guard let enumerator = fm.enumerator(
            at: Self.baseDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var urlsToRemove: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            urlsToRemove.append(fileURL)
        }

        for url in urlsToRemove {
            try? fm.removeItem(at: url)
        }
        cache = cache.filter { _, url in fm.fileExists(atPath: url.path) }

        // Remove empty message directories
        if let dirs = try? fm.contentsOfDirectory(at: Self.baseDirectory, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                if contents.isEmpty { try? fm.removeItem(at: dir) }
            }
        }
    }
}
