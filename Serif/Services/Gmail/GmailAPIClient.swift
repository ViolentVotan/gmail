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
        guard let url = URL(string: urlString) else { throw .invalidURL }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        let path = url.path + (url.query.map { "?\($0)" } ?? "")

        #if DEBUG
        let t0 = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw GmailAPIError.invalidURL }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            await APILogger.shared.log(APILogEntry(
                method: "GET", path: path, statusCode: http.statusCode, errorMessage: nil,
                responseBodyData: data, responseSize: data.count, durationMs: ms, fromCache: false
            ))
            guard (200...299).contains(http.statusCode) else { throw GmailAPIError.httpError(http.statusCode, data) }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw GmailAPIError.decodingError(error) }
        } catch let error as GmailAPIError {
            throw error
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            await APILogger.shared.log(APILogEntry(
                method: "GET", path: path, statusCode: nil, errorMessage: error.localizedDescription,
                responseBodyData: Data(), responseSize: 0, durationMs: ms, fromCache: false
            ))
            throw .networkError(error)
        }
        #else
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw .networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidURL }
        guard (200...299).contains(http.statusCode) else { throw .httpError(http.statusCode, data) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw .decodingError(error) }
        #endif
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

        // Delegate network I/O + parsing to @concurrent helper (mirrors rawRequest → perform pattern)
        return try await performBatch(requests: requests, accessToken: token.accessToken)
    }

    /// Executes batch HTTP call off the main actor. Mirrors the `perform()` pattern.
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
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Serif/1.0", forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = bodyData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw .networkError(error)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw .httpError(code, data)
        }

        guard let contentType = http.value(forHTTPHeaderField: "Content-Type"),
              let responseBoundary = contentType.components(separatedBy: "boundary=").last?.trimmingCharacters(in: .whitespaces) else {
            throw .decodingError(URLError(.cannotParseResponse))
        }

        return try Self.parseBatchResponse(data: data, boundary: responseBoundary)
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
        guard let token else {
            throw .unauthorized
        }
        guard token.isExpired else { return token }

        // Coalesce concurrent refresh calls per account
        if let existing = refreshTasks[accountID] {
            do {
                return try await existing.value
            } catch {
                throw .wrap(error)
            }
        }

        let task = Task<AuthToken, Error> {
            defer { self.refreshTasks[accountID] = nil }
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

    /// Forces a token refresh (invalidates cached token). Used for 401 auto-retry.
    private func refreshAndRetry(accountID: String) async throws(GmailAPIError) -> AuthToken {
        refreshTasks[accountID] = nil
        let token: AuthToken?
        do {
            token = try TokenStore.shared.retrieve(for: accountID)
        } catch {
            throw .networkError(error)
        }
        guard let token else { throw .unauthorized }
        let task = Task<AuthToken, Error> {
            defer { self.refreshTasks[accountID] = nil }
            let fresh = try await OAuthService.shared.refreshToken(token)
            try TokenStore.shared.save(fresh, for: accountID)
            return fresh
        }
        refreshTasks[accountID] = task
        do {
            return try await task.value
        } catch {
            throw GmailAPIError.wrap(error)
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
            request.setValue("Serif/1.0", forHTTPHeaderField: "User-Agent")
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
                    // Intentionally use try? — if task is cancelled, the next iteration's
                    // URLSession call will throw, which we convert to .networkError.
                    try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt)))
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
        case 429, 500, 503: return true
        default: return false
        }
    }

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let base = pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...(base * 0.5))
        return base + jitter
    }
}
