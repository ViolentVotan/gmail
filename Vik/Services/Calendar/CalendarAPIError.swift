import Foundation

enum CalendarAPIError: Error, LocalizedError, Sendable {
    case invalidURL
    case unauthorized
    case offline
    case tokenRevoked
    case httpError(Int, Data)
    case decodingError(Error)
    case encodingError(Error)
    case networkError(Error)
    case notFound
    case conflict(etag: String)
    case rateLimited(retryAfter: Int)
    case gone
    case insufficientPermissions

    var errorDescription: String? {
        switch self {
        case .invalidURL:                    return "Invalid Calendar API URL"
        case .unauthorized:                  return "Unauthorized — please sign in again"
        case .offline:                       return "You're offline — please check your connection"
        case .tokenRevoked:                  return "Session expired — please sign in again"
        case .httpError(let c, _):           return "HTTP \(c)"
        case .decodingError:                 return "Failed to process server response"
        case .encodingError:                 return "Failed to prepare request"
        case .networkError(let e):           return "Network error: \(e.localizedDescription)"
        case .notFound:                      return "Calendar resource not found"
        case .conflict:                       return "This event was modified elsewhere — please refresh and try again"
        case .rateLimited(let after):        return "Rate limited — retry after \(after)s"
        case .gone:                          return "Calendar resource permanently deleted"
        case .insufficientPermissions:       return "Calendar access not granted — reauthorization required"
        }
    }

    /// Whether this error should not be retried (the action should be discarded).
    var isNonRetriable: Bool {
        switch self {
        case .conflict, .gone, .notFound, .tokenRevoked, .unauthorized: true
        default: false
        }
    }

    /// Wraps an arbitrary error into a `CalendarAPIError`, passing through if already one.
    /// Maps `GmailAPIError.tokenRevoked` and `GmailAPIError.unauthorized` for cross-client delegation.
    static func wrap(_ error: Error) -> CalendarAPIError {
        if let calError = error as? CalendarAPIError { return calError }
        if let gmailError = error as? GmailAPIError {
            switch gmailError {
            case .tokenRevoked:  return .tokenRevoked
            case .unauthorized:  return .unauthorized
            case .offline:       return .offline
            case .networkError(let e): return .networkError(e)
            default: return .networkError(gmailError)
            }
        }
        return .networkError(error)
    }
}
