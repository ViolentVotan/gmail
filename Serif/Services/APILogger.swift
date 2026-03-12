import Foundation
import Observation

// MARK: - API Log Entry

struct APILogEntry: Identifiable, Sendable {
    let id              = UUID()
    let date            = Date()
    let method          : String
    let path            : String
    let statusCode      : Int?
    let errorMessage    : String?
    let requestHeaders  : [String: String]
    let requestBody     : String?
    let responseHeaders : [String: String]
    let responseBody    : String
    let responseSize    : Int
    let durationMs      : Int
    let fromCache       : Bool
    let bodyTruncated   : Bool

    private static let maxBodyBytes = 200_000  // 200 KB

    /// Build an entry, truncating response body if needed.
    init(method: String, path: String, statusCode: Int?, errorMessage: String?,
         requestHeaders: [String: String] = [:], requestBody: String? = nil,
         responseHeaders: [String: String] = [:],
         responseBodyData: Data, responseSize: Int, durationMs: Int, fromCache: Bool) {
        self.method          = method
        self.path            = path
        self.statusCode      = statusCode
        self.errorMessage    = errorMessage
        self.requestHeaders  = requestHeaders
        self.requestBody     = requestBody
        self.responseHeaders = responseHeaders
        self.responseSize    = responseSize
        self.durationMs      = durationMs
        self.fromCache       = fromCache

        let limit = APILogEntry.maxBodyBytes
        if responseBodyData.count > limit {
            self.responseBody    = (String(data: responseBodyData.prefix(limit), encoding: .utf8) ?? "") + "\n…[truncated]"
            self.bodyTruncated   = true
        } else {
            self.responseBody    = String(data: responseBodyData, encoding: .utf8) ?? ""
            self.bodyTruncated   = false
        }
    }

    var shortPath: String {
        String(path.split(separator: "?").first ?? Substring(path))
    }

    enum StatusLevel { case success, cached, warning, error }

    var statusLevel: StatusLevel {
        guard let code = statusCode else { return .error }
        switch code {
        case 200...299: return fromCache ? .cached : .success
        case 429:       return .warning
        default:        return .error
        }
    }

    var statusLabel: String {
        if fromCache      { return "CACHE" }
        if let code = statusCode { return "\(code)" }
        return "ERR"
    }
}

// MARK: - API Logger

@Observable
@MainActor
final class APILogger {
    static let shared = APILogger()
    private init() {}

    private(set) var entries: [APILogEntry] = []
    private let maxEntries = 200

    func log(_ entry: APILogEntry) {
        if entries.count >= maxEntries { entries.removeFirst() }
        entries.append(entry)
    }

    func clear() { entries = [] }
}

