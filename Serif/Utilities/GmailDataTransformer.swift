import Foundation
private import CryptoKit

/// Pure-data utilities for transforming Gmail API responses into app models.
/// All methods are static and have no side effects on app state.
enum GmailDataTransformer {

    // MARK: - Contact Parsing

    @MainActor static func parseContact(_ raw: String) -> Contact {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Contact(name: "Unknown", email: "") }
        if let ltIdx = trimmed.lastIndex(of: "<"),
           let gtIdx = trimmed.lastIndex(of: ">"),
           ltIdx < gtIdx {
            let name  = String(trimmed[..<ltIdx])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let email = String(trimmed[trimmed.index(after: ltIdx)..<gtIdx]).trimmingCharacters(in: .whitespaces)
            return Contact(name: name.isEmpty ? email : name, email: email,
                           avatarColor: avatarColor(for: email), avatarURL: resolveAvatarURL(for: email))
        }
        return Contact(name: trimmed, email: trimmed,
                       avatarColor: avatarColor(for: trimmed), avatarURL: resolveAvatarURL(for: trimmed))
    }

    @MainActor static func parseContacts(_ raw: String) -> [Contact] {
        guard !raw.isEmpty else { return [] }
        // Split on commas while respecting quoted strings and angle brackets.
        // e.g. `"Doe, John" <john@example.com>, Jane <jane@example.com>`
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngleBracket = false
        for ch in raw {
            switch ch {
            case "\"":
                inQuotes.toggle()
                current.append(ch)
            case "<":
                inAngleBracket = true
                current.append(ch)
            case ">":
                inAngleBracket = false
                current.append(ch)
            case ",":
                if inQuotes || inAngleBracket {
                    current.append(ch)
                } else {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { parts.append(trimmed) }
                    current = ""
                }
            default:
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts.map { parseContact($0) }
    }

    // MARK: - Attachment

    static func makeAttachment(from part: GmailMessagePart, messageId: String) -> Attachment {
        let name = part.filename ?? "attachment"
        let ext  = String(name.split(separator: ".").last ?? "")
        let size = part.body.map { sizeString($0.size) } ?? ""
        return Attachment(name: name, fileType: .from(fileExtension: ext), size: size,
                          gmailAttachmentId: part.body?.attachmentId, gmailMessageId: messageId, mimeType: part.mimeType)
    }

    // MARK: - Folder

    static func folderFor(labelIDs: [String]) -> Folder {
        if labelIDs.contains(GmailSystemLabel.sent)  { return .sent }
        if labelIDs.contains(GmailSystemLabel.draft) { return .drafts }
        if labelIDs.contains(GmailSystemLabel.spam)  { return .spam }
        if labelIDs.contains(GmailSystemLabel.trash) { return .trash }
        return .inbox
    }

    // MARK: - UUID

    /// Generates a stable UUID from a Gmail message ID string using SHA256.
    static func deterministicUUID(from gmailID: String) -> UUID {
        let hash = SHA256.hash(data: Data(gmailID.utf8))
        let bytes = Array(hash)
        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Avatar

    static func avatarColor(for email: String) -> String {
        avatarColors[Int(stableHash(email) % UInt64(avatarColors.count))]
    }

    /// Returns the best available avatar URL for an email address:
    /// 1. Google People API (contacts with uploaded photos)
    /// 2. Signed-in account profile picture
    /// 3. Gravatar (SHA-256, d=404 so AvatarCache handles misses gracefully)
    @MainActor static func resolveAvatarURL(for email: String) -> String {
        if let url = ContactPhotoCache.shared.get(email) { return url }
        if let url = AccountStore.shared.accounts.first(where: { $0.email == email })?.profilePictureURL?.absoluteString { return url }
        return gravatarURL(for: email)
    }

    // MARK: - Private helpers

    private static let avatarColors = [
        "#6C5CE7", "#00B894", "#E17055", "#0984E3",
        "#FDCB6E", "#E84393", "#00CEC9", "#A29BFE"
    ]

    private static func gravatarURL(for email: String) -> String {
        let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
        let hash = SHA256.hash(data: Data(normalized.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "https://gravatar.com/avatar/\(hex)?s=80&d=404"
    }

    static func sizeString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func sizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
