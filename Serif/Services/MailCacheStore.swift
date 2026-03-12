import Foundation

/// Wrapper that stores messages alongside pagination state.
struct FolderCache: Codable, Sendable {
    var messages: [GmailMessage]
    var nextPageToken: String?
}

/// File-based cache for mails, labels, and threads — per account + folder.
@MainActor
final class MailCacheStore {
    static let shared = MailCacheStore()
    private var createdDirs: Set<String> = []
    private var tagStore: [String: EmailTags] = [:]

    private init() {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    private let baseDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.genyus.serif.app/mail-cache", isDirectory: true)
    }()

    private func fileURL(accountID: String, folderKey: String) -> URL {
        let accountDir = baseDir.appendingPathComponent(accountID, isDirectory: true)
        if !createdDirs.contains(accountID) {
            try? FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
            createdDirs.insert(accountID)
        }
        let safe = folderKey.replacingOccurrences(of: "/", with: "_")
        return accountDir.appendingPathComponent("\(safe).json")
    }

    /// Computes file URL without creating directories — safe to call from any isolation domain.
    nonisolated private func readFileURL(accountID: String, folderKey: String) -> URL {
        let safe = folderKey.replacingOccurrences(of: "/", with: "_")
        return baseDir
            .appendingPathComponent(accountID, isDirectory: true)
            .appendingPathComponent("\(safe).json")
    }

    /// Computes thread file URL without creating directories.
    nonisolated private func readThreadURL(accountID: String, threadID: String) -> URL {
        baseDir
            .appendingPathComponent(accountID, isDirectory: true)
            .appendingPathComponent("threads", isDirectory: true)
            .appendingPathComponent("\(threadID).json")
    }

    /// Builds a stable cache key from label IDs and optional query.
    static func folderKey(labelIDs: [String], query: String?) -> String {
        let base = labelIDs.sorted().joined(separator: "+")
        if let q = query, !q.isEmpty {
            let safe = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
            return "\(base)_q_\(String(safe.prefix(100)))"
        }
        return base.isEmpty ? "_all" : base
    }

    // MARK: - Messages (FolderCache — with pagination metadata)

    @concurrent func loadFolderCache(accountID: String, folderKey: String) async -> FolderCache {
        let url = readFileURL(accountID: accountID, folderKey: folderKey)
        guard let data = try? Data(contentsOf: url) else { return FolderCache(messages: []) }
        if let cache = try? JSONDecoder().decode(FolderCache.self, from: data) {
            return cache
        }
        if let messages = try? JSONDecoder().decode([GmailMessage].self, from: data) {
            return FolderCache(messages: messages)
        }
        return FolderCache(messages: [])
    }

    func saveFolderCache(_ cache: FolderCache, accountID: String, folderKey: String) {
        let url = fileURL(accountID: accountID, folderKey: folderKey)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Messages (legacy — used by switchAccount and other non-folder code)

    @concurrent func load(accountID: String, folderKey: String) async -> [GmailMessage] {
        await loadFolderCache(accountID: accountID, folderKey: folderKey).messages
    }

    func save(_ messages: [GmailMessage], accountID: String, folderKey: String) {
        let url = fileURL(accountID: accountID, folderKey: folderKey)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(messages) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Labels

    @concurrent func loadLabels(accountID: String) async -> [GmailLabel] {
        let url = readFileURL(accountID: accountID, folderKey: "_labels")
        guard let data = try? Data(contentsOf: url),
              let labels = try? JSONDecoder().decode([GmailLabel].self, from: data)
        else { return [] }
        return labels
    }

    func saveLabels(_ labels: [GmailLabel], accountID: String) {
        let url = fileURL(accountID: accountID, folderKey: "_labels")
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(labels) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Threads (full format, for offline HTML)

    private func threadURL(accountID: String, threadID: String) -> URL {
        let key = "\(accountID)/threads"
        let dir = baseDir.appendingPathComponent(accountID, isDirectory: true)
            .appendingPathComponent("threads", isDirectory: true)
        if !createdDirs.contains(key) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            createdDirs.insert(key)
        }
        return dir.appendingPathComponent("\(threadID).json")
    }

    @concurrent func loadThread(accountID: String, threadID: String) async -> GmailThread? {
        let url = readThreadURL(accountID: accountID, threadID: threadID)
        guard let data = try? Data(contentsOf: url),
              let thread = try? JSONDecoder().decode(GmailThread.self, from: data)
        else { return nil }
        return thread
    }

    func saveThread(_ thread: GmailThread, accountID: String) {
        let url = threadURL(accountID: accountID, threadID: thread.id)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(thread) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func deleteAccount(_ accountID: String) {
        let accountDir = baseDir.appendingPathComponent(accountID, isDirectory: true)
        try? FileManager.default.removeItem(at: accountDir)
    }

    // MARK: - Email Tags (AI classification results)

    /// Pending save task — coalesces rapid tag writes into a single disk write.
    private var tagSaveTask: Task<Void, Never>?

    func saveTags(_ tags: EmailTags, for messageId: String, accountID: String) {
        tagStore[messageId] = tags
        scheduleTagSave(accountID: accountID)
    }

    /// Saves multiple tags at once (batch classification). Single disk write.
    func saveTagsBatch(_ batch: [(messageId: String, tags: EmailTags)], accountID: String) {
        for (messageId, tags) in batch {
            tagStore[messageId] = tags
        }
        scheduleTagSave(accountID: accountID)
    }

    func loadTags(for messageId: String) -> EmailTags? {
        tagStore[messageId]
    }

    func loadTagsFromDisk(accountID: String) async {
        let tags = await readTagsFromDisk(accountID: accountID)
        if let tags {
            tagStore.merge(tags) { _, new in new }
        }
    }

    @concurrent private func readTagsFromDisk(accountID: String) async -> [String: EmailTags]? {
        let url = readFileURL(accountID: accountID, folderKey: "_tags")
        guard let data = try? Data(contentsOf: url),
              let tags = try? JSONDecoder().decode([String: EmailTags].self, from: data)
        else { return nil }
        return tags
    }

    /// Debounces tag saves: waits 500ms for additional writes before flushing to disk.
    private func scheduleTagSave(accountID: String) {
        tagSaveTask?.cancel()
        tagSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            flushTagsToDisk(accountID: accountID)
        }
    }

    private func flushTagsToDisk(accountID: String) {
        let url = fileURL(accountID: accountID, folderKey: "_tags")
        let snapshot = tagStore
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
