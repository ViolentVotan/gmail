import Foundation

@MainActor
final class GmailSendService {
    static let shared = GmailSendService()
    private init() {}

    // MARK: - Send

    @concurrent func send(
        from: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        body: String,
        isHTML: Bool = false,
        threadID: String? = nil,
        referencesHeader: String? = nil,
        inlineImages: [InlineImageAttachment] = [],
        attachments: [URL]? = nil,
        accountID: String
    ) async throws(GmailAPIError) -> GmailMessage {
        let raw = try Self.buildRawMessage(
            from: from, to: to, cc: cc, bcc: bcc,
            subject: subject, body: body, isHTML: isHTML,
            referencesHeader: referencesHeader,
            inlineImages: inlineImages,
            attachments: attachments ?? []
        )
        var payload: [String: Any] = ["raw": raw]
        if let threadID { payload["threadId"] = threadID }
        let encoded: Data
        do {
            encoded = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw .encodingError(error)
        }
        return try await GmailAPIClient.shared.request(
            path: "/users/me/messages/send",
            method: "POST", body: encoded, contentType: "application/json",
            accountID: accountID
        )
    }

    // MARK: - MIME Building (used by GmailDraftService)

    /// Builds a base64url-encoded RFC 2822 message. Used by GmailDraftService for draft payloads.
    /// Static so callers don't need MainActor access to the `shared` singleton.
    nonisolated static func buildRawMessage(
        from: String, to: [String], cc: [String], bcc: [String] = [],
        subject: String, body: String, isHTML: Bool,
        referencesHeader: String? = nil,
        inlineImages: [InlineImageAttachment] = [],
        attachments: [URL] = []
    ) throws(GmailAPIError) -> String {
        if !attachments.isEmpty || !inlineImages.isEmpty {
            return try buildRawMultipart(
                from: from, to: to, cc: cc, bcc: bcc,
                subject: subject, body: body, isHTML: isHTML,
                referencesHeader: referencesHeader,
                inlineImages: inlineImages, attachments: attachments
            )
        }
        return try buildRaw(from: from, to: to, cc: cc, bcc: bcc,
                           subject: subject, body: body, isHTML: isHTML,
                           referencesHeader: referencesHeader)
    }

    // MARK: - RFC 2822 Builder (plain / HTML)

    nonisolated private static func buildRaw(
        from: String,
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        body: String,
        isHTML: Bool,
        referencesHeader: String? = nil
    ) throws(GmailAPIError) -> String {
        if isHTML {
            // multipart/alternative: text/plain + text/html
            let boundary = "BA_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            var lines = [
                "MIME-Version: 1.0",
                "From: \(mimeEncodeAddress(from))",
                "To: \(mimeEncodeAddresses(to))",
                "Subject: \(mimeEncodeHeader(subject))",
                "Content-Type: multipart/alternative; boundary=\"\(boundary)\""
            ]
            if !cc.isEmpty  { lines.append("Cc: \(mimeEncodeAddresses(cc))") }
            if !bcc.isEmpty { lines.append("Bcc: \(mimeEncodeAddresses(bcc))") }
            if let ref = referencesHeader {
                lines.append("In-Reply-To: \(ref)")
                lines.append("References: \(ref)")
            }

            var mime = lines.joined(separator: "\r\n") + "\r\n\r\n"
            mime += "--\(boundary)\r\n"
            mime += "Content-Type: text/plain; charset=UTF-8\r\n"
            mime += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            mime += body.strippingHTML + "\r\n"
            mime += "--\(boundary)\r\n"
            mime += "Content-Type: text/html; charset=UTF-8\r\n"
            mime += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            mime += body + "\r\n"
            mime += "--\(boundary)--"
            return try base64URLEncode(mime)
        } else {
            var lines = [
                "MIME-Version: 1.0",
                "From: \(mimeEncodeAddress(from))",
                "To: \(mimeEncodeAddresses(to))",
                "Subject: \(mimeEncodeHeader(subject))",
                "Content-Type: text/plain; charset=UTF-8",
                "Content-Transfer-Encoding: 8bit"
            ]
            if !cc.isEmpty  { lines.append("Cc: \(mimeEncodeAddresses(cc))") }
            if !bcc.isEmpty { lines.append("Bcc: \(mimeEncodeAddresses(bcc))") }
            if let ref = referencesHeader {
                lines.append("In-Reply-To: \(ref)")
                lines.append("References: \(ref)")
            }
            let raw = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
            return try base64URLEncode(raw)
        }
    }

    // MARK: - RFC 2822 Builder (multipart/mixed + multipart/related)

    nonisolated private static func buildRawMultipart(
        from: String,
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        body: String,
        isHTML: Bool = true,
        referencesHeader: String? = nil,
        inlineImages: [InlineImageAttachment] = [],
        attachments: [URL]
    ) throws(GmailAPIError) -> String {
        let boundaryMixed = "BM_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let boundaryRelated = "BR_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let boundaryAlt = "BA_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let hasInline = !inlineImages.isEmpty
        let hasFileAttachments = !attachments.isEmpty

        let topBoundary: String
        let topType: String
        if hasFileAttachments {
            topBoundary = boundaryMixed
            topType = "multipart/mixed"
        } else if hasInline {
            topBoundary = boundaryRelated
            topType = "multipart/related"
        } else {
            topBoundary = boundaryMixed
            topType = "multipart/mixed"
        }

        var lines = [
            "MIME-Version: 1.0",
            "From: \(mimeEncodeAddress(from))",
            "To: \(mimeEncodeAddresses(to))",
            "Subject: \(mimeEncodeHeader(subject))",
            "Content-Type: \(topType); boundary=\"\(topBoundary)\""
        ]
        if !cc.isEmpty  { lines.append("Cc: \(mimeEncodeAddresses(cc))") }
        if !bcc.isEmpty { lines.append("Bcc: \(mimeEncodeAddresses(bcc))") }
        if let ref = referencesHeader {
            lines.append("In-Reply-To: \(ref)")
            lines.append("References: \(ref)")
        }

        var mime = lines.joined(separator: "\r\n") + "\r\n\r\n"

        // Helper: builds the body part (multipart/alternative when HTML, or plain text/html part)
        func bodyPart(boundary: String) -> String {
            var part = ""
            if isHTML {
                part += "--\(boundary)\r\n"
                part += "Content-Type: multipart/alternative; boundary=\"\(boundaryAlt)\"\r\n\r\n"
                part += "--\(boundaryAlt)\r\n"
                part += "Content-Type: text/plain; charset=UTF-8\r\n"
                part += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                part += body.strippingHTML + "\r\n"
                part += "--\(boundaryAlt)\r\n"
                part += "Content-Type: text/html; charset=UTF-8\r\n"
                part += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                part += body + "\r\n"
                part += "--\(boundaryAlt)--\r\n"
            } else {
                part += "--\(boundary)\r\n"
                part += "Content-Type: text/plain; charset=UTF-8\r\n"
                part += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                part += body + "\r\n"
            }
            return part
        }

        if hasFileAttachments && hasInline {
            mime += "--\(boundaryMixed)\r\n"
            mime += "Content-Type: multipart/related; boundary=\"\(boundaryRelated)\"\r\n\r\n"
            mime += bodyPart(boundary: boundaryRelated)
            mime += encodeInlineImages(inlineImages, boundary: boundaryRelated)
            mime += "--\(boundaryRelated)--\r\n"
            mime += try encodeFileAttachments(attachments, boundary: boundaryMixed)
            mime += "--\(boundaryMixed)--"

        } else if hasInline {
            mime += bodyPart(boundary: boundaryRelated)
            mime += encodeInlineImages(inlineImages, boundary: boundaryRelated)
            mime += "--\(boundaryRelated)--"

        } else {
            mime += bodyPart(boundary: boundaryMixed)
            mime += try encodeFileAttachments(attachments, boundary: boundaryMixed)
            mime += "--\(boundaryMixed)--"
        }

        return try base64URLEncode(mime)
    }

    // MARK: - MIME Part Encoding Helpers

    /// Encodes inline images as MIME parts with Content-ID for HTML `cid:` references.
    nonisolated private static func encodeInlineImages(_ images: [InlineImageAttachment], boundary: String) -> String {
        var mime = ""
        for img in images {
            let encoded = img.data.base64EncodedString(options: .lineLength76Characters)
            mime += "--\(boundary)\r\n"
            mime += "Content-Type: \(img.mimeType)\r\n"
            mime += "Content-ID: <\(img.contentID)>\r\n"
            mime += "Content-Disposition: inline; filename=\"\(img.filename)\"\r\n"
            mime += "Content-Transfer-Encoding: base64\r\n\r\n"
            mime += encoded + "\r\n"
        }
        return mime
    }

    /// Encodes file attachments as MIME parts. Throws if any file cannot be read.
    nonisolated private static func encodeFileAttachments(_ urls: [URL], boundary: String) throws(GmailAPIError) -> String {
        var mime = ""
        var failedFilenames: [String] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                failedFilenames.append(url.lastPathComponent)
                continue
            }
            let encoded = data.base64EncodedString(options: .lineLength76Characters)
            mime += "--\(boundary)\r\n"
            mime += "Content-Type: \(url.mimeType)\r\n"
            mime += "Content-Disposition: attachment; filename=\"\(url.lastPathComponent)\"\r\n"
            mime += "Content-Transfer-Encoding: base64\r\n\r\n"
            mime += encoded + "\r\n"
        }
        if !failedFilenames.isEmpty { throw .attachmentReadFailed(failedFilenames) }
        return mime
    }

    // MARK: - Helpers

    /// RFC 2047 encode a header value when it contains non-ASCII characters (e.g. emojis).
    nonisolated private static func mimeEncodeHeader(_ value: String) -> String {
        let needsEncoding = value.unicodeScalars.contains { !$0.isASCII }
        guard needsEncoding, let data = value.data(using: .utf8) else { return value }
        let encoded = data.base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }

    /// RFC 2047 encodes the display name portion of an email address.
    /// `"Andre Meyer" <andre@example.com>` → `"=?UTF-8?B?...?=" <andre@example.com>`
    /// Leaves bare email addresses and ASCII-only names unchanged.
    nonisolated private static func mimeEncodeAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let ltIdx = trimmed.lastIndex(of: "<"),
              let gtIdx = trimmed.lastIndex(of: ">"),
              ltIdx < gtIdx else {
            // Bare email address — no display name to encode
            return trimmed
        }
        let displayName = String(trimmed[..<ltIdx]).trimmingCharacters(in: .whitespaces)
        let emailPart = String(trimmed[ltIdx...]) // includes <email>
        guard !displayName.isEmpty else { return trimmed }
        let encodedName = mimeEncodeHeader(displayName.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        return "\(encodedName) \(emailPart)"
    }

    /// Applies RFC 2047 display-name encoding to a list of addresses.
    nonisolated private static func mimeEncodeAddresses(_ addresses: [String]) -> String {
        addresses.map { mimeEncodeAddress($0) }.joined(separator: ", ")
    }

    nonisolated private static func base64URLEncode(_ string: String) throws(GmailAPIError) -> String {
        guard let data = string.data(using: .utf8) else {
            throw .encodingError(URLError(.cannotParseResponse))
        }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
