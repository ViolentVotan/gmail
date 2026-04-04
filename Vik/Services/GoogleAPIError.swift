import Foundation

/// Unified API error type shared by Gmail, Calendar, and Pub/Sub services.
/// Domain-specific cases coexist so callers can pattern-match the subset they care about.
enum GoogleAPIError: Error, LocalizedError, Sendable {
    // MARK: - Common
    case invalidURL
    case unauthorized
    case offline
    case tokenRevoked
    case httpError(Int, Data)
    case decodingError(any Error)
    case encodingError(any Error)
    case networkError(any Error)
    case insufficientPermissions

    // MARK: - Gmail-specific
    case partialFailure(failedCount: Int)
    case attachmentReadFailed([String])
    case dailyLimitExceeded
    case domainPolicy

    // MARK: - Calendar-specific
    case notFound
    case conflict(etag: String)
    case rateLimited(retryAfter: Int)
    case gone

    // MARK: - Pub/Sub-specific
    /// OAuth token lacks the `pubsub` scope -- re-authorization can fix this.
    case insufficientScope(accountID: String)
    /// IAM permission denied or API disabled -- re-authorization will NOT fix this.
    case permissionDenied(accountID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:                      return "Invalid API URL"
        case .unauthorized:                    return "Unauthorized -- please sign in again"
        case .offline:                         return "You're offline -- please check your connection"
        case .tokenRevoked:                    return "Session expired -- please sign in again"
        case .httpError(let c, _):             return "HTTP \(c)"
        case .decodingError:                   return "Failed to process server response"
        case .encodingError:                   return "Failed to prepare request"
        case .networkError(let e):             return "Network error: \(e.localizedDescription)"
        case .insufficientPermissions:         return "Insufficient permissions -- please reauthorize"
        case .partialFailure(let count):       return "Failed to delete \(count) messages"
        case .attachmentReadFailed(let names): return "Could not read attachments: \(names.joined(separator: ", "))"
        case .dailyLimitExceeded:              return "Gmail daily API limit exceeded -- try again tomorrow"
        case .domainPolicy:                    return "Blocked by domain policy -- contact your administrator"
        case .notFound:                        return "Resource not found"
        case .conflict:                        return "This resource was modified elsewhere -- please refresh and try again"
        case .rateLimited(let after):          return "Rate limited -- retry after \(after)s"
        case .gone:                            return "Resource permanently deleted"
        case .insufficientScope:               return "Missing API scope -- please reauthorize"
        case .permissionDenied(_, let reason): return "Permission denied: \(reason)"
        }
    }

    /// Whether this error should not be retried (the action should be discarded).
    var isNonRetriable: Bool {
        switch self {
        case .conflict, .gone, .notFound, .tokenRevoked, .unauthorized: true
        default: false
        }
    }

    /// Wraps an arbitrary error into a `GoogleAPIError`, passing through if already one.
    /// Maps `OAuthError.tokenRevoked` to `.tokenRevoked` so callers get a clear signal.
    static func wrap(_ error: any Error) -> GoogleAPIError {
        if let apiError = error as? GoogleAPIError { return apiError }
        if let oauthError = error as? OAuthError {
            switch oauthError {
            case .tokenRevoked, .noRefreshToken: return .tokenRevoked
            default: break
            }
        }
        return .networkError(error)
    }
}
