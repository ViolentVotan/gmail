import AppKit
import PDFKit

/// In-memory cache of attachment thumbnails, loaded on-demand.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    /// Cached thumbnails keyed by attachment ID.
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    /// IDs currently being fetched (to avoid duplicate requests).
    private var loading: Set<String> = []

    private let maxSize = CGSize(width: 300, height: 200)

    func clearAll() {
        thumbnails.removeAll()
        loading.removeAll()
    }

    func thumbnail(for id: String) -> NSImage? {
        thumbnails[id]
    }

    /// Request a thumbnail for an attachment. Downloads the data, generates a thumbnail, and caches it.
    func loadIfNeeded(attachment: IndexedAttachment, accountID: String) {
        let id = attachment.id
        guard thumbnails[id] == nil, !loading.contains(id) else { return }

        let fileType = Attachment.FileType(rawValue: attachment.fileType) ?? .document
        guard fileType == .image || fileType == .pdf else { return }

        loading.insert(id)
        let msgId = attachment.messageId
        let attId = attachment.attachmentId

        Task {
            defer { loading.remove(id) }
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
