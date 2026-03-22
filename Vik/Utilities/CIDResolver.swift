import Foundation

/// Unified CID image resolver — replaces `cid:` references in HTML with `data:` URIs.
///
/// Supports two resolution paths:
/// - **Embedded data**: base64url-encoded data already present in `part.body.data` (common in
///   full-format draft responses).
/// - **Attachment fetch**: downloads the attachment via the Gmail API when only an attachment ID
///   is available.
///
/// Callers control behavior via parameters:
/// - `preserveDataCID`: when `true`, replaces `src="cid:X"` with `src="<dataURI>" data-cid="X"`
///   (needed by the compose editor to round-trip inline images). When `false`, replaces bare
///   `cid:X` references with the data URI.
/// - `concurrent`: when `true`, fetches attachments in parallel via `TaskGroup`. When `false`,
///   processes parts sequentially (appropriate when already inside a concurrent context).
enum CIDResolver {

    @concurrent static func resolve(
        html: String,
        inlineParts: [GmailMessagePart],
        messageID: String,
        accountID: String,
        api: any MessageFetching,
        preserveDataCID: Bool = false,
        concurrent: Bool = true
    ) async -> String {
        guard !inlineParts.isEmpty, html.contains("cid:") else { return html }

        if concurrent {
            return await resolveConcurrently(
                html: html, inlineParts: inlineParts,
                messageID: messageID, accountID: accountID,
                api: api, preserveDataCID: preserveDataCID
            )
        } else {
            return await resolveSequentially(
                html: html, inlineParts: inlineParts,
                messageID: messageID, accountID: accountID,
                api: api, preserveDataCID: preserveDataCID
            )
        }
    }

    // MARK: - Private

    private static func resolveConcurrently(
        html: String,
        inlineParts: [GmailMessagePart],
        messageID: String,
        accountID: String,
        api: any MessageFetching,
        preserveDataCID: Bool
    ) async -> String {
        var result = html
        await withTaskGroup(of: (String, String, String?).self) { group in
            for part in inlineParts {
                guard let cid = part.contentID,
                      let mime = part.mimeType else { continue }
                group.addTask {
                    let b64 = await fetchBase64(part: part, messageID: messageID, accountID: accountID, api: api)
                    return (cid, mime, b64)
                }
            }
            for await (cid, mime, b64) in group {
                guard let b64 else { continue }
                let dataURI = "data:\(mime);base64,\(b64)"
                result = applyReplacement(html: result, cid: cid, dataURI: dataURI, preserveDataCID: preserveDataCID)
            }
        }
        return result
    }

    private static func resolveSequentially(
        html: String,
        inlineParts: [GmailMessagePart],
        messageID: String,
        accountID: String,
        api: any MessageFetching,
        preserveDataCID: Bool
    ) async -> String {
        var result = html
        for part in inlineParts {
            guard let cid = part.contentID,
                  let mime = part.mimeType else { continue }
            guard let b64 = await fetchBase64(part: part, messageID: messageID, accountID: accountID, api: api) else { continue }
            let dataURI = "data:\(mime);base64,\(b64)"
            result = applyReplacement(html: result, cid: cid, dataURI: dataURI, preserveDataCID: preserveDataCID)
        }
        return result
    }

    /// Resolves base64 image data from either embedded body data or an attachment fetch.
    private static func fetchBase64(
        part: GmailMessagePart,
        messageID: String,
        accountID: String,
        api: any MessageFetching
    ) async -> String? {
        // Prefer embedded base64url data (present in full-format responses)
        if let embedded = part.body?.data {
            return Data(base64URLEncoded: embedded)?.base64EncodedString()
        }
        // Fall back to attachment fetch
        guard let attID = part.body?.attachmentId else { return nil }
        guard let data = try? await api.getAttachment(
            messageID: messageID, attachmentID: attID, accountID: accountID
        ) else { return nil }
        return data.base64EncodedString()
    }

    /// Applies the CID-to-data-URI replacement in the HTML string.
    private static func applyReplacement(html: String, cid: String, dataURI: String, preserveDataCID: Bool) -> String {
        if preserveDataCID {
            return html.replacingOccurrences(
                of: "src=\"cid:\(cid)\"",
                with: "src=\"\(dataURI)\" data-cid=\"\(cid)\""
            )
        } else {
            return html.replacingOccurrences(of: "cid:\(cid)", with: dataURI)
        }
    }
}
