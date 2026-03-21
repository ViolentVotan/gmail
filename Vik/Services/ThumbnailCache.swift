import AppKit
import Observation
import PDFKit

/// In-memory + disk cache of attachment thumbnails, loaded on-demand with concurrency throttling.
@Observable
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private init() {}

    /// Tracks which attachment IDs have a cached thumbnail; observed by SwiftUI to trigger re-renders.
    private(set) var cachedIDs: Set<String> = []

    @ObservationIgnored private let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    /// IDs currently being fetched (to avoid duplicate requests).
    @ObservationIgnored private var loading: Set<String> = []

    /// Pending thumbnail requests queued when at capacity.
    @ObservationIgnored private var pendingQueue: [(id: String, attachment: IndexedAttachment, accountID: String)] = []

    /// Number of active concurrent fetches.
    @ObservationIgnored private var activeFetches = 0
    private let maxConcurrentFetches = 4

    /// Tracks in-flight fetch tasks so they can be cancelled on clearAll().
    @ObservationIgnored private var fetchTasks: [String: Task<Void, Never>] = [:]

    /// Tracks saveToDisk tasks so they can be cancelled on clearAll() to prevent stale thumbnails.
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]

    private let maxSize = CGSize(width: 300, height: 200)

    /// Injected attachment-fetching capability for testability.
    /// Defaults to the real Gmail API service.
    @ObservationIgnored
    var fetchAttachment: @Sendable (_ messageID: String, _ attachmentID: String, _ accountID: String) async throws -> Data = { messageID, attachmentID, accountID in
        try await GmailMessageService.shared.getAttachment(
            messageID: messageID, attachmentID: attachmentID, accountID: accountID
        )
    }

    /// Directory for disk-cached thumbnails.
    private let cacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #if DEBUG
        let name = "com.vikingz.vik.thumbnails-debug"
        #else
        let name = "com.vikingz.vik.thumbnails"
        #endif
        let dir = caches.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func clearAll() {
        fetchTasks.values.forEach { $0.cancel() }
        fetchTasks.removeAll()
        saveTasks.values.forEach { $0.cancel() }
        saveTasks.removeAll()
        thumbnailCache.removeAllObjects()
        cachedIDs.removeAll()
        loading.removeAll()
        pendingQueue.removeAll()
        activeFetches = 0
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func thumbnail(for id: String) -> NSImage? {
        guard cachedIDs.contains(id) else { return nil }
        return thumbnailCache.object(forKey: id as NSString)
    }

    /// Cancel a pending thumbnail load if the card scrolled offscreen before the fetch started.
    func cancelIfNeeded(id: String) {
        pendingQueue.removeAll { $0.id == id }
    }

    /// Request a thumbnail for an attachment. Loads from disk cache first, then network.
    func loadIfNeeded(attachment: IndexedAttachment, accountID: String) {
        let id = attachment.id
        guard thumbnailCache.object(forKey: id as NSString) == nil, !loading.contains(id) else { return }

        let fileType = Attachment.FileType(rawValue: attachment.fileType) ?? .document
        guard fileType == .image || fileType == .pdf else { return }

        loading.insert(id)

        // Check disk cache off the main actor, then fall through to network if needed.
        let cacheDir = cacheDirectory
        let task = Task {
            if let diskImage = await Self.loadFromDisk(id: id, cacheDir: cacheDir) {
                guard !Task.isCancelled else { return }
                self.loading.remove(id)
                self.thumbnailCache.setObject(diskImage, forKey: id as NSString)
                self.cachedIDs.insert(id)
                return
            }
            // Disk miss — hand off to the throttled network fetch.
            guard !Task.isCancelled, self.thumbnailCache.object(forKey: id as NSString) == nil else {
                self.loading.remove(id)
                return
            }
            if self.activeFetches < self.maxConcurrentFetches {
                self.startFetch(id: id, attachment: attachment, accountID: accountID)
            } else {
                self.pendingQueue.append((id: id, attachment: attachment, accountID: accountID))
            }
        }
        fetchTasks[id] = task
    }

    // MARK: - Fetch

    private func startFetch(id: String, attachment: IndexedAttachment, accountID: String) {
        activeFetches += 1
        let msgId = attachment.messageId
        let attId = attachment.attachmentId
        let fileType = Attachment.FileType(rawValue: attachment.fileType) ?? .document

        let task = Task {
            defer {
                fetchTasks.removeValue(forKey: id)
                loading.remove(id)
                activeFetches = max(0, activeFetches - 1)
                dequeueNext()
            }
            do {
                let data = try await self.fetchAttachment(msgId, attId, accountID)
                guard !Task.isCancelled else { return }
                let thumb: NSImage? = switch fileType {
                case .image: await Self.imageThumb(from: data, maxSize: maxSize)
                case .pdf:   await Self.pdfThumb(from: data, maxSize: maxSize)
                default:     nil
                }
                if let thumb {
                    thumbnailCache.setObject(thumb, forKey: id as NSString)
                    cachedIDs.insert(id)
                    saveToDisk(image: thumb, id: id)
                }
            } catch {
                // Silently skip — will show icon fallback
            }
        }
        fetchTasks[id] = task
    }

    private func dequeueNext() {
        guard activeFetches < maxConcurrentFetches, !pendingQueue.isEmpty else { return }
        let next = pendingQueue.removeFirst()
        // Skip if cancelled (removed from loading) or already cached
        guard loading.contains(next.id), thumbnailCache.object(forKey: next.id as NSString) == nil else {
            loading.remove(next.id)
            dequeueNext()
            return
        }
        startFetch(id: next.id, attachment: next.attachment, accountID: next.accountID)
    }

    // MARK: - Disk Cache

    @concurrent private static func loadFromDisk(id: String, cacheDir: URL) async -> NSImage? {
        let safeName = id.replacingOccurrences(of: "/", with: "_")
        let url = cacheDir.appendingPathComponent(safeName + ".jpg")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 90 * 24 * 3600 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private func saveToDisk(image: NSImage, id: String) {
        let safeName = id.replacingOccurrences(of: "/", with: "_")
        let url = cacheDirectory.appendingPathComponent(safeName + ".jpg")
        let cacheDir = cacheDirectory
        let task = Task { [weak self] in
            await Self.writeThumbnail(image: image, url: url, cacheDir: cacheDir)
            self?.saveTasks.removeValue(forKey: id)
        }
        saveTasks[id] = task
    }

    @concurrent private static func writeThumbnail(image: NSImage, url: URL, cacheDir: URL) async {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else { return }
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try jpeg.write(to: url)
        } catch {
            // Directory may have been removed by concurrent clearAll(); skip silently
        }
    }

    // MARK: - Generators

    @concurrent private static func imageThumb(from data: Data, maxSize: CGSize) async -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1.0)
        let thumbSize = CGSize(width: size.width * scale, height: size.height * scale)
        let originalSize = size
        let thumb = NSImage(size: thumbSize, flipped: false) { rect in
            image.draw(in: rect, from: NSRect(origin: .zero, size: originalSize), operation: .copy, fraction: 1.0)
            return true
        }
        return thumb
    }

    @concurrent private static func pdfThumb(from data: Data, maxSize: CGSize) async -> NSImage? {
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(maxSize.width / bounds.width, maxSize.height / bounds.height, 1.0)
        let thumbSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let thumb = page.thumbnail(of: thumbSize, for: .mediaBox)
        return thumb
    }
}
