import Foundation
import AppKit

// MARK: - FileUtils

enum FileUtils {
    /// Canonical set of image extensions recognized across the app.
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp"]

    /// Presents an NSSavePanel and writes `data` to the chosen location.
    @MainActor
    static func saveWithPanel(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

// MARK: - URL Extensions

extension URL {
    /// SF Symbols icon name for this file's extension.
    var sfSymbolIcon: String {
        switch pathExtension.lowercased() {
        case "pdf":
            return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp":
            return "photo"
        case "doc", "docx", "pages", "txt", "rtf":
            return "doc"
        case "xls", "xlsx", "csv", "numbers":
            return "tablecells"
        case "ppt", "pptx", "key":
            return "play.rectangle"
        case "zip", "gz", "tar", "rar", "7z":
            return "archivebox"
        case "swift", "py", "js", "ts", "html", "css", "json", "xml", "sh":
            return "chevron.left.forwardslash.chevron.right"
        case "mp3", "m4a", "wav", "aiff", "flac":
            return "waveform"
        case "mp4", "mov", "avi", "mkv":
            return "film"
        default:
            return "doc"
        }
    }

    /// Whether this URL points to an image file.
    var isImage: Bool {
        FileUtils.imageExtensions.contains(pathExtension.lowercased())
    }

    /// Whether this file type is safe to send as email attachment.
    var isEmailCompatible: Bool {
        let allowed: Set<String> = [
            // Images
            "jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp", "svg", "ico",
            // Documents
            "pdf", "doc", "docx", "pages", "txt", "rtf", "odt",
            // Spreadsheets
            "xls", "xlsx", "csv", "numbers", "ods",
            // Presentations
            "ppt", "pptx", "key", "odp",
            // Archives
            "zip", "gz", "tar", "rar", "7z",
            // Audio
            "mp3", "m4a", "wav", "aiff", "flac", "ogg", "aac",
            // Video
            "mp4", "mov", "avi", "mkv", "webm",
            // Code / text
            "json", "xml", "html", "htm", "css", "js", "ts", "py", "swift", "sh", "md", "yaml", "yml",
            // Other
            "ics", "vcf", "eml"
        ]
        return allowed.contains(pathExtension.lowercased())
    }

    /// MIME type string for this file's extension.
    var mimeType: String {
        switch pathExtension.lowercased() {
        case "pdf":                                     return "application/pdf"
        case "jpg", "jpeg":                             return "image/jpeg"
        case "png":                                     return "image/png"
        case "gif":                                     return "image/gif"
        case "webp":                                    return "image/webp"
        case "txt":                                     return "text/plain"
        case "html", "htm":                             return "text/html"
        case "doc":                                     return "application/msword"
        case "docx":                                    return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls":                                     return "application/vnd.ms-excel"
        case "xlsx":                                    return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt":                                     return "application/vnd.ms-powerpoint"
        case "pptx":                                    return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "zip":                                     return "application/zip"
        case "gz":                                      return "application/gzip"
        case "json":                                    return "application/json"
        case "xml":                                     return "application/xml"
        case "mp3":                                     return "audio/mpeg"
        case "mp4":                                     return "video/mp4"
        case "mov":                                     return "video/quicktime"
        default:                                        return "application/octet-stream"
        }
    }
}
