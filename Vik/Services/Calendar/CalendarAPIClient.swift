import Foundation
private import os

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the Calendar API returns 403 `insufficientPermissions`.
    /// `userInfo` contains `[CalendarAPIClient.accountIDKey: String]`.
    static let calendarScopesInsufficient = Notification.Name("CalendarAPIClient.calendarScopesInsufficient")
}

// MARK: - CalendarAPIClient

@MainActor
final class CalendarAPIClient {
    static let shared = CalendarAPIClient()
    private init() {}

    /// Key for the account ID in `calendarScopesInsufficient` notification's userInfo.
    static let accountIDKey = "accountID"

    private let baseURL = "https://www.googleapis.com/calendar/v3"
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "CalendarAPI")

    // MARK: - Decoded requests

    /// Performs an authenticated Calendar API request and decodes the JSON response.
    @concurrent func request<T: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        queryItems: [URLQueryItem]? = nil,
        accountID: String
    ) async throws(CalendarAPIError) -> T {
        let data = try await requestData(path: path, method: method, body: body, queryItems: queryItems, accountID: accountID)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .decodingError(error)
        }
    }

    /// Performs an authenticated Calendar API request, returning raw Data.
    /// Use for DELETE and other responses that carry no body.
    @concurrent func requestVoid(
        path: String,
        method: String,
        body: Data? = nil,
        queryItems: [URLQueryItem]? = nil,
        accountID: String
    ) async throws(CalendarAPIError) {
        _ = try await requestData(path: path, method: method, body: body, queryItems: queryItems, accountID: accountID)
    }

    // MARK: - Core request

    @concurrent private func requestData(
        path: String,
        method: String,
        body: Data?,
        queryItems: [URLQueryItem]?,
        accountID: String
    ) async throws(CalendarAPIError) -> Data {
        guard NetworkMonitor.isReachable else { throw .offline }

        // Delegate token management to GmailAPIClient — no token duplication.
        let token: AuthToken
        do {
            token = try await GmailAPIClient.shared.validCalendarToken(for: accountID)
        } catch {
            throw CalendarAPIError.wrap(error)
        }

        do {
            return try await perform(path: path, method: method, body: body, queryItems: queryItems, accessToken: token.accessToken, accountID: accountID)
        } catch CalendarAPIError.unauthorized {
            // 401: force refresh via GmailAPIClient, then retry once
            let fresh: AuthToken
            do {
                fresh = try await GmailAPIClient.shared.refreshCalendarToken(for: accountID)
            } catch {
                throw CalendarAPIError.wrap(error)
            }
            return try await perform(path: path, method: method, body: body, queryItems: queryItems, accessToken: fresh.accessToken, accountID: accountID)
        }
    }

    // MARK: - HTTP layer

    @concurrent private func perform(
        path: String,
        method: String,
        body: Data?,
        queryItems: [URLQueryItem]?,
        accessToken: String,
        accountID: String
    ) async throws(CalendarAPIError) -> Data {
        guard var components = URLComponents(string: baseURL + path) else { throw .invalidURL }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }
        guard let url = components.url else { throw .invalidURL }

        for attempt in 0...RetryPolicy.maxRetries {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("Vik/1.0 (gzip)", forHTTPHeaderField: "User-Agent")
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = body

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await GmailAPIClient.sharedSession.data(for: request)
            } catch {
                if RetryPolicy.isRetriableNetworkError(error), attempt < RetryPolicy.maxRetries {
                    try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt)))
                    continue
                }
                throw .networkError(error)
            }
            guard let http = response as? HTTPURLResponse else { throw .invalidURL }

            switch http.statusCode {
            case 200...299:
                return data
            case 401:
                throw .unauthorized
            case 404:
                throw .notFound
            case 409:
                let etag = http.value(forHTTPHeaderField: "ETag")
                    ?? http.value(forHTTPHeaderField: "Etag")
                    ?? ""
                throw .conflict(etag: etag)
            case 410:
                throw .gone
            case 429:
                if attempt < RetryPolicy.maxRetries {
                    let retryAfterHeader = http.value(forHTTPHeaderField: "Retry-After")
                    let retryAfterSecs = retryAfterHeader.flatMap(Int.init) ?? 0
                    try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt, retryAfter: retryAfterHeader)))
                    _ = retryAfterSecs // captured above for the error case
                    continue
                }
                let retryAfterSecs = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? 0
                throw .rateLimited(retryAfter: retryAfterSecs)
            case 403:
                if RetryPolicy.isRateLimited403(data), attempt < RetryPolicy.maxRetries {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt, retryAfter: retryAfter)))
                    continue
                }
                if let body = String(data: data, encoding: .utf8), body.contains("insufficientPermissions") {
                    Self.logger.warning("Calendar API: insufficientPermissions for account \(accountID) — posting reauth notification")
                    await postInsufficientPermissionsNotification(accountID: accountID)
                    throw .insufficientPermissions
                }
                throw .httpError(http.statusCode, data)
            default:
                if RetryPolicy.isRetriable(statusCode: http.statusCode), attempt < RetryPolicy.maxRetries {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt, retryAfter: retryAfter)))
                    continue
                }
                throw .httpError(http.statusCode, data)
            }
        }
        throw .httpError(0, Data())
    }

    // MARK: - Scope reauthorization

    /// Posts a notification so the UI can prompt the user to reauthorize with calendar scopes.
    private func postInsufficientPermissionsNotification(accountID: String) {
        NotificationCenter.default.post(
            name: .calendarScopesInsufficient,
            object: self,
            userInfo: [Self.accountIDKey: accountID]
        )
    }
}
