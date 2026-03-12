import Foundation

/// Base HTTP client for all Gmail API requests.
/// Automatically refreshes expired tokens before each call.
@MainActor
final class GmailAPIClient {
    static let shared = GmailAPIClient()
    private init() {}

    private let baseURL = "https://gmail.googleapis.com/gmail/v1"
    private var refreshTasks: [String: Task<AuthToken, Error>] = [:]

    // MARK: - Decoded requests

    func request<T: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        fields: String? = nil,
        accountID: String
    ) async throws(GmailAPIError) -> T {
        let data = try await rawRequest(path: path, method: method, body: body, contentType: contentType, fields: fields, accountID: accountID)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .decodingError(error)
        }
    }

    /// Returns raw Data (e.g. for DELETE responses or binary payloads).
    func rawRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        fields: String? = nil,
        accountID: String
    ) async throws(GmailAPIError) -> Data {
        guard NetworkMonitor.shared.isConnected else { throw .offline }
        let token = try await validToken(for: accountID)

        // First attempt + 401 auto-retry
        do {
            return try await doPerform(path: path, method: method, body: body, contentType: contentType, fields: fields, accessToken: token.accessToken)
        } catch .unauthorized {
            let fresh = try await refreshAndRetry(accountID: accountID)
            return try await doPerform(path: path, method: method, body: body, contentType: contentType, fields: fields, accessToken: fresh.accessToken)
        }
    }

    // MARK: - Authenticated request to any Google API URL

    /// Makes an authenticated GET request to any Google API (not limited to the Gmail base URL).
    func requestURL<T: Decodable>(_ urlString: String, accountID: String) async throws(GmailAPIError) -> T {
        guard NetworkMonitor.shared.isConnected else { throw .offline }
        let token = try await validToken(for: accountID)

        let doRequest = { (accessToken: String) async throws(GmailAPIError) -> T in
            let data = try await self.performURL(urlString, accessToken: accessToken)
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw GmailAPIError.decodingError(error)
            }
        }

        do {
            return try await doRequest(token.accessToken)
        } catch .unauthorized {
            let fresh = try await refreshAndRetry(accountID: accountID)
            return try await doRequest(fresh.accessToken)
        }
    }

    // MARK: - Batch requests

    /// Sends up to 50 individual API requests in a single HTTP call using Gmail's batch endpoint.
    /// Each part is a standalone HTTP request encoded in `multipart/mixed`.
    /// Returns an array of (contentID, responseData) tuples. Individual parts may fail independently.
    func batchRequest(
        requests: [(id: String, method: String, path: String, body: Data?)],
        accountID: String
    ) async throws(GmailAPIError) -> [(id: String, statusCode: Int, data: Data)] {
        guard NetworkMonitor.shared.isConnected else { throw .offline }
        let token = try await validToken(for: accountID)

        // First attempt + 401 auto-retry (mirrors rawRequest pattern)
        do {
            return try await performBatch(requests: requests, accessToken: token.accessToken)
        } catch .unauthorized {
            let fresh = try await refreshAndRetry(accountID: accountID)
            return try await performBatch(requests: requests, accessToken: fresh.accessToken)
        }
    }

    /// Generic batch fetch: chunks IDs into batches of 50, decodes each successful response.
    /// `pathBuilder` must return full API paths starting with `/gmail/v1/...` (not relative to baseURL).
    func batchFetch<T: Decodable>(
        ids: [String],
        pathBuilder: @Sendable (String) -> String,
        accountID: String
    ) async throws(GmailAPIError) -> [T] {
        guard !ids.isEmpty else { return [] }
        let batchSize = 50
        var all: [T] = []
        let decoder = JSONDecoder()

        for offset in stride(from: 0, to: ids.count, by: batchSize) {
            let batch = Array(ids[offset..<min(offset + batchSize, ids.count)])
            let requests = batch.map { id in
                (id: id, method: "GET", path: pathBuilder(id), body: nil as Data?)
            }
            let results = try await batchRequest(requests: requests, accountID: accountID)
            for result in results {
                guard (200...299).contains(result.statusCode) else {
                    #if DEBUG
                    print("[GmailAPI] Batch part \(result.id) failed: HTTP \(result.statusCode)")
                    #endif
                    continue
                }
                do {
                    let item = try decoder.decode(T.self, from: result.data)
                    all.append(item)
                } catch {
                    #if DEBUG
                    print("[GmailAPI] Batch decode failed for \(result.id): \(error)")
                    #endif
                }
            }
        }
        return all
    }

    // MARK: - Perform for arbitrary Google API URLs

    /// Executes an authenticated GET to any full URL (not limited to Gmail base URL).
    @concurrent private func performURL(
        _ urlString: String,
        accessToken: String
    ) async throws(GmailAPIError) -> Data {
        guard let url = URL(string: urlString) else { throw .invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Serif/1.0 (gzip)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw .networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidURL }
        if http.statusCode == 401 { throw .unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw .httpError(http.statusCode, data)
        }
        return data
    }

    /// Executes batch HTTP call off the main actor with retry logic matching `perform()`.
    @concurrent private func performBatch(
        requests: [(id: String, method: String, path: String, body: Data?)],
        accessToken: String
    ) async throws(GmailAPIError) -> [(id: String, statusCode: Int, data: Data)] {
        let boundary = "batch_serif_\(UUID().uuidString)"
        var bodyParts: [String] = []

        for req in requests {
            var part = "--\(boundary)\r\n"
            part += "Content-Type: application/http\r\n"
            part += "Content-ID: <\(req.id)>\r\n\r\n"
            part += "\(req.method) \(req.path) HTTP/1.1\r\n"
            part += "Content-Type: application/json\r\n"
            if let bodyData = req.body, let bodyStr = String(data: bodyData, encoding: .utf8) {
                part += "Content-Length: \(bodyData.count)\r\n\r\n"
                part += bodyStr
            } else {
                part += "\r\n"
            }
            bodyParts.append(part)
        }

        let fullBody = bodyParts.joined(separator: "\r\n") + "\r\n--\(boundary)--"
        guard let bodyData = fullBody.data(using: .utf8) else { throw .encodingError(URLError(.cannotParseResponse)) }

        guard let url = URL(string: "https://www.googleapis.com/batch/gmail/v1") else { throw .invalidURL }

        for attempt in 0...RetryPolicy.maxRetries {
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Serif/1.0 (gzip)", forHTTPHeaderField: "User-Agent")
            urlRequest.httpBody = bodyData

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: urlRequest)
            } catch {
                throw .networkError(error)
            }
            guard let http = response as? HTTPURLResponse else {
                throw .invalidURL
            }

            switch http.statusCode {
            case 200...299:
                guard let contentType = http.value(forHTTPHeaderField: "Content-Type"),
                      let responseBoundary = contentType.components(separatedBy: "boundary=").last?.trimmingCharacters(in: .whitespaces) else {
                    throw .decodingError(URLError(.cannotParseResponse))
                }
                return try Self.parseBatchResponse(data: data, boundary: responseBoundary)
            case 401:
                throw .unauthorized
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

    nonisolated private static func parseBatchResponse(data: Data, boundary: String) throws(GmailAPIError) -> [(id: String, statusCode: Int, data: Data)] {
        guard let responseString = String(data: data, encoding: .utf8) else {
            throw .decodingError(URLError(.cannotParseResponse))
        }

        var results: [(id: String, statusCode: Int, data: Data)] = []
        let parts = responseString.components(separatedBy: "--\(boundary)")

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "--" else { continue }

            // Extract Content-ID
            var contentID = ""
            if let idRange = trimmed.range(of: "Content-ID: <") {
                let afterID = trimmed[idRange.upperBound...]
                if let endRange = afterID.range(of: ">") {
                    contentID = String(afterID[..<endRange.lowerBound])
                }
            }

            // Find the HTTP response line and body
            guard let httpRange = trimmed.range(of: "HTTP/1.1 ") else { continue }
            let httpPart = trimmed[httpRange.upperBound...]
            let statusEnd = httpPart.index(httpPart.startIndex, offsetBy: 3, limitedBy: httpPart.endIndex) ?? httpPart.endIndex
            let statusCode = Int(httpPart[..<statusEnd]) ?? 0

            // Body is after double CRLF in the HTTP response part
            let httpFull = trimmed[httpRange.lowerBound...]
            if let bodyStart = httpFull.range(of: "\r\n\r\n") ?? httpFull.range(of: "\n\n") {
                let bodyString = String(httpFull[bodyStart.upperBound...])
                results.append((id: contentID, statusCode: statusCode, data: Data(bodyString.utf8)))
            } else {
                results.append((id: contentID, statusCode: statusCode, data: Data()))
            }
        }

        return results
    }

    // MARK: - Token refresh

    private func validToken(for accountID: String) async throws(GmailAPIError) -> AuthToken {
        let token: AuthToken?
        do {
            token = try TokenStore.shared.retrieve(for: accountID)
        } catch {
            throw .networkError(error)
        }
        guard let token else { throw .unauthorized }
        guard token.isExpired else { return token }
        return try await performRefresh(for: accountID)
    }

    /// Forces a token refresh (invalidates cached token). Used for 401 auto-retry.
    private func refreshAndRetry(accountID: String) async throws(GmailAPIError) -> AuthToken {
        refreshTasks[accountID] = nil
        return try await performRefresh(for: accountID)
    }

    /// Creates (or reuses) a refresh task for the given account and awaits it.
    /// Coalesces concurrent refresh calls — only one network request per account at a time.
    private func performRefresh(for accountID: String) async throws(GmailAPIError) -> AuthToken {
        if let existing = refreshTasks[accountID] {
            do {
                return try await existing.value
            } catch {
                throw .wrap(error)
            }
        }

        let task = Task<AuthToken, Error> {
            defer { self.refreshTasks[accountID] = nil }
            let token: AuthToken?
            do {
                token = try TokenStore.shared.retrieve(for: accountID)
            } catch {
                throw GmailAPIError.networkError(error)
            }
            guard let token else { throw GmailAPIError.unauthorized }
            let fresh = try await OAuthService.shared.refreshToken(token)
            try TokenStore.shared.save(fresh, for: accountID)
            return fresh
        }
        refreshTasks[accountID] = task
        do {
            return try await task.value
        } catch {
            throw .wrap(error)
        }
    }

    // MARK: - Perform with logging

    /// Wraps `perform()` with DEBUG logging. Extracted to allow 401 retry without duplicating logic.
    private func doPerform(
        path: String,
        method: String,
        body: Data?,
        contentType: String?,
        fields: String?,
        accessToken: String
    ) async throws(GmailAPIError) -> Data {
        #if DEBUG
        let reqHeaders: [String: String] = {
            var h = ["Authorization": "Bearer [hidden]"]
            if let ct = contentType { h["Content-Type"] = ct }
            return h
        }()
        let reqBody: String? = body.flatMap { String(data: $0, encoding: .utf8) }
        let t0 = Date()
        do {
            let (data, code, respHeaders) = try await perform(path: path, method: method, body: body, contentType: contentType, fields: fields, accessToken: accessToken)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            APILogger.shared.log(APILogEntry(
                method: method, path: path, statusCode: code, errorMessage: nil,
                requestHeaders: reqHeaders, requestBody: reqBody,
                responseHeaders: respHeaders,
                responseBodyData: data, responseSize: data.count, durationMs: ms, fromCache: false
            ))
            if let encoding = respHeaders["Content-Encoding"] {
                print("[GmailAPI] Compression: \(encoding) for \(path)")
            }
            return data
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if case .httpError(let code, let errData) = error {
                APILogger.shared.log(APILogEntry(
                    method: method, path: path, statusCode: code, errorMessage: "HTTP \(code)",
                    requestHeaders: reqHeaders, requestBody: reqBody,
                    responseBodyData: errData, responseSize: errData.count, durationMs: ms, fromCache: false
                ))
            } else {
                APILogger.shared.log(APILogEntry(
                    method: method, path: path, statusCode: nil, errorMessage: error.localizedDescription,
                    requestHeaders: reqHeaders, requestBody: reqBody,
                    responseBodyData: Data(), responseSize: 0, durationMs: ms, fromCache: false
                ))
            }
            throw error
        }
        #else
        let (data, _, _) = try await perform(path: path, method: method, body: body, contentType: contentType, fields: fields, accessToken: accessToken)
        return data
        #endif
    }

    // MARK: - HTTP layer

    /// Returns (data, httpStatusCode, responseHeaders).
    @concurrent private func perform(
        path: String,
        method: String,
        body: Data?,
        contentType: String?,
        fields: String?,
        accessToken: String
    ) async throws(GmailAPIError) -> (Data, Int, [String: String]) {
        var fullPath = path
        if let fields {
            let separator = fullPath.contains("?") ? "&" : "?"
            let encoded = fields.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fields
            fullPath += "\(separator)fields=\(encoded)"
        }
        guard let url = URL(string: baseURL + fullPath) else { throw .invalidURL }

        for attempt in 0...RetryPolicy.maxRetries {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("Serif/1.0 (gzip)", forHTTPHeaderField: "User-Agent")
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            request.httpBody = body

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw .networkError(error)
            }
            guard let http = response as? HTTPURLResponse else { throw .invalidURL }

            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String, let val = pair.value as? String { result[key] = val }
            }

            switch http.statusCode {
            case 200...299:
                return (data, http.statusCode, headers)
            case 401:
                throw .unauthorized
            default:
                if RetryPolicy.isRetriable(statusCode: http.statusCode), attempt < RetryPolicy.maxRetries {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    // Intentionally use try? — if task is cancelled, the next iteration's
                    // URLSession call will throw, which we convert to .networkError.
                    try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt, retryAfter: retryAfter)))
                    continue
                }
                throw .httpError(http.statusCode, data)
            }
        }
        throw .httpError(0, Data())
    }
}

// MARK: - Errors

enum GmailAPIError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case offline
    case httpError(Int, Data)
    case decodingError(Error)
    case encodingError(Error)
    case partialFailure(failedCount: Int)
    case networkError(Error)
    case attachmentReadFailed([String])

    var errorDescription: String? {
        switch self {
        case .invalidURL:                      return "Invalid API URL"
        case .unauthorized:                    return "Unauthorized — please sign in again"
        case .offline:                         return "You're offline — please check your connection"
        case .httpError(let c, _):             return "HTTP \(c)"
        case .decodingError(let e):            return "Decode failed: \(e.localizedDescription)"
        case .encodingError(let e):            return "Encode failed: \(e.localizedDescription)"
        case .partialFailure(let count):       return "Failed to delete \(count) messages"
        case .networkError(let e):             return "Network error: \(e.localizedDescription)"
        case .attachmentReadFailed(let names): return "Could not read attachments: \(names.joined(separator: ", "))"
        }
    }

    /// Wraps an arbitrary error into a `GmailAPIError`, passing through if already one.
    static func wrap(_ error: Error) -> GmailAPIError {
        if let apiError = error as? GmailAPIError { return apiError }
        return .networkError(error)
    }
}

// MARK: - Retry Policy

enum RetryPolicy {
    static let maxRetries = 3

    static func isRetriable(statusCode: Int) -> Bool {
        switch statusCode {
        case 429, 500, 502, 503, 504: return true
        default: return false
        }
    }

    /// Computes retry delay. Honors `Retry-After` header from Google on 429 responses,
    /// otherwise falls back to exponential backoff with jitter.
    static func delay(forAttempt attempt: Int, retryAfter: String? = nil) -> TimeInterval {
        if let retryAfter, let seconds = TimeInterval(retryAfter) {
            return seconds
        }
        let base = pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...(base * 0.5))
        return base + jitter
    }
}

// MARK: - Path Builder

enum GmailPathBuilder {
    /// Builds a single `&labelIds=...` query parameter with URL encoding.
    static func labelQueryParam(_ labelID: String) -> String {
        let encoded = labelID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? labelID
        return "&labelIds=\(encoded)"
    }

    /// Builds the path for a sendAs endpoint with URL-encoded email.
    static func sendAsPath(_ email: String) -> String {
        let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? email
        return "/users/me/settings/sendAs/\(encoded)"
    }
}
