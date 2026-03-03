import AppKit
import PDFKit

/// In-memory cache of attachment thumbnails, loaded on-demand with concurrency throttling.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    /// Cached thumbnails keyed by attachment ID.
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    /// IDs currently being fetched (to avoid duplicate requests).
    private var loading: Set<String> = []

    /// Pending thumbnail requests queued when at capacity.
    private var pendingQueue: [(id: String, attachment: IndexedAttachment, accountID: String)] = []

    /// Number of active concurrent fetches.
    private var activeFetches = 0
    private let maxConcurrentFetches = 4

    private let maxSize = CGSize(width: 300, height: 200)

    func clearAll() {
        thumbnails.removeAll()
        loading.removeAll()
        pendingQueue.removeAll()
    }

    func thumbnail(for id: String) -> NSImage? {
        thumbnails[id]
    }

    /// Cancel a pending thumbnail load if the card scrolled offscreen before the fetch started.
    func cancelIfNeeded(id: String) {
        pendingQueue.removeAll { $0.id == id }
    }

    /// Request a thumbnail for an attachment. Queues if at concurrency limit.
    func loadIfNeeded(attachment: IndexedAttachment, accountID: String) {
        let id = attachment.id
        guard thumbnails[id] == nil, !loading.contains(id) else { return }

        let fileType = Attachment.FileType(rawValue: attachment.fileType) ?? .document
        guard fileType == .image || fileType == .pdf else { return }

        loading.insert(id)

        if activeFetches < maxConcurrentFetches {
            startFetch(id: id, attachment: attachment, accountID: accountID)
        } else {
            pendingQueue.append((id: id, attachment: attachment, accountID: accountID))
        }
    }

    // MARK: - Fetch

    private func startFetch(id: String, attachment: IndexedAttachment, accountID: String) {
        activeFetches += 1
        let msgId = attachment.messageId
        let attId = attachment.attachmentId
        let fileType = Attachment.FileType(rawValue: attachment.fileType) ?? .document

        Task {
            defer {
                loading.remove(id)
                activeFetches -= 1
                dequeueNext()
            }
            do {
                let data = try await GmailMessageService.shared.getAttachment(
                    messageID: msgId,
                    attachmentID: attId,
                    accountID: accountID
                )
                let thumb: NSImage? = switch fileType {
                case .image: Self.imageThumb(from: data, maxSize: maxSize)
                case .pdf:   Self.pdfThumb(from: data, maxSize: maxSize)
                default:     nil
                }
                if let thumb {
                    thumbnails[id] = thumb
                }
            } catch {
                // Silently skip — will show icon fallback
            }
        }
    }

    private func dequeueNext() {
        guard activeFetches < maxConcurrentFetches, !pendingQueue.isEmpty else { return }
        let next = pendingQueue.removeFirst()
        // Skip if cancelled (removed from loading) or already cached
        guard loading.contains(next.id), thumbnails[next.id] == nil else {
            loading.remove(next.id)
            dequeueNext()
            return
        }
        startFetch(id: next.id, attachment: next.attachment, accountID: next.accountID)
    }

    // MARK: - Generators

    private static func imageThumb(from data: Data, maxSize: CGSize) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1.0)
        let thumbSize = CGSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: thumbSize)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: thumbSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        return thumb
    }

    private static func pdfThumb(from data: Data, maxSize: CGSize) -> NSImage? {
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
