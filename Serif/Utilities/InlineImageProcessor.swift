import Foundation

struct InlineImageAttachment: Sendable {
    let contentID: String
    let data: Data
    let mimeType: String
    let filename: String
}

enum InlineImageProcessor {

    private static let inlineImageRegex: NSRegularExpression = {
        let pattern = #"<img\s[^>]*src="data:([^;]+);base64,([^"]+)"[^>]*data-cid="([^"]+)"[^>]*>"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Scans HTML for `<img src="data:..." data-cid="...">` tags,
    /// extracts the base64 data, replaces with `<img src="cid:...">`.
    static func extractInlineImages(from html: String) -> (html: String, images: [InlineImageAttachment]) {
        var images: [InlineImageAttachment] = []
        let nsHTML = html as NSString
        let mutable = NSMutableString(string: html)
        let regex = Self.inlineImageRegex
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        // Process in reverse so NSRange offsets remain valid after each replacement
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4 else { continue }

            let mimeType = nsHTML.substring(with: match.range(at: 1))
            let base64Str = nsHTML.substring(with: match.range(at: 2))
            let cid = nsHTML.substring(with: match.range(at: 3))

            guard let data = Data(base64Encoded: base64Str, options: .ignoreUnknownCharacters) else { continue }

            let ext = mimeType.contains("png") ? "png" : "jpg"
            images.insert(InlineImageAttachment(
                contentID: cid,
                data: data,
                mimeType: mimeType,
                filename: "\(cid).\(ext)"
            ), at: 0)

            let replacement = "<img src=\"cid:\(cid)\">"
            mutable.replaceCharacters(in: match.range, with: replacement)
        }

        return (mutable as String, images)
    }
}
