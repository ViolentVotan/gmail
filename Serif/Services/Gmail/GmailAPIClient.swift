import Foundation
import os.log

/// Base HTTP client for all Gmail API requests.
/// Automatically refreshes expired tokens before each call.
@MainActor
final class GmailAPIClient {
    static let shared = GmailAPIClient()
    private init() {}

    private let baseURL = "https://gmail.googleapis.com/gmail/v1"
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.serif", category: "GmailAPI")
    private var refreshTasks: [String: Task<AuthToken, Error>] = [:]
    private var refreshGeneration: [String: Int] = [:]

    /// Configured session for Google API calls: appropriate timeouts,
    /// connection pooling, and connectivity waiting.
    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

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

    // MARK: - ETag-aware request

    /// Makes a GET request with optional `If-None-Match` header for cache validation.
    /// Returns `nil` when the server responds with 304 Not Modified.
    /// Returns `(decoded, etag)` on 200, where `etag` is the ETag header value if present.
    func requestWithETag<T: Decodable>(
        path: String,
        etag: String?,
        fields: String? = nil,
        accountID: String
    ) async throws(GmailAPIError) -> (T, String?)? {
        guard NetworkMonitor.shared.isConnected else { throw .offline }
        let token = try await validToken(for: accountID)

        let doRequest = { (accessToken: String) async throws(GmailAPIError) -> (T, String?)? in
            try await self.performWithETag(
                path: path, etag: etag, fields: fields, accessToken: accessToken
            )
        }

        do {
            return try await doRequest(token.accessToken)
        } catch .unauthorized {
            let fresh = try await refreshAndRetry(accountID: accountID)
            return try await doRequest(fresh.accessToken)
        }
    }

    @concurrent private func performWithETag<T: Decodable>(
        path: String,
        etag: String?,
        fields: String?,
        accessToken: String
    ) async throws(GmailAPIError) -> (T, String?)? {
        var fullPath = path
        if let fields {
            let separator = fullPath.contains("?") ? "&" : "?"
            let encoded = fields.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fields
            fullPath += "\(separator)fields=\(encoded)"
        }
        guard let url = URL(string: baseURL + fullPath) else { throw .invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Serif/1.0 (gzip)", forHTTPHeaderField: "User-Agent")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw .networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidURL }

        switch http.statusCode {
        case 304:
            return nil
        case 200...299:
            let responseETag = http.value(forHTTPHeaderField: "ETag")
                ?? http.value(forHTTPHeaderField: "Etag")
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                return (decoded, responseETag)
            } catch {
                throw .decodingError(error)
            }
        case 401:
            throw .unauthorized
        default:
            throw .httpError(http.statusCode, data)
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
    /// Parts that fail with HTTP 429 are automatically retried with exponential backoff (up to 3 attempts).
    func batchRequest(
        requests: [(id: String, method: String, path: String, body: Data?)],
        accountID: String
    ) async throws(GmailAPIError) -> [(id: String, statusCode: Int, data: Data)] {
        guard NetworkMonitor.shared.isConnected else { throw .offline }
        let token = try await validToken(for: accountID)
        var activeAccessToken = token.accessToken

        // First attempt + 401 auto-retry (mirrors rawRequest pattern)
        let initialResults: [(id: String, statusCode: Int, data: Data)]
        do {
            initialResults = try await performBatch(requests: requests, accessToken: activeAccessToken)
        } catch .unauthorized {
            let fresh = try await refreshAndRetry(accountID: accountID)
            activeAccessToken = fresh.accessToken
            initialResults = try await performBatch(requests: requests, accessToken: activeAccessToken)
        }

        // Retry any parts that failed with HTTP 429 (rate limited)
        return try await retryRateLimitedParts(
            allResults: initialResults,
            originalRequests: requests,
            accessToken: activeAccessToken,
            accountID: accountID
        )
    }

    /// Retries batch parts that returned HTTP 429, using exponential backoff.
    /// Merges successful results from retries with the original successes.
    /// Limited to `maxPartRetries` attempts to prevent infinite loops.
    private func retryRateLimitedParts(
        allResults: [(id: String, statusCode: Int, data: Data)],
        originalRequests: [(id: String, method: String, path: String, body: Data?)],
        accessToken: String,
        accountID: String
    ) async throws(GmailAPIError) -> [(id: String, statusCode: Int, data: Data)] {
        let maxPartRetries = 3
        let requestsByID = Dictionary(uniqueKeysWithValues: originalRequests.map { ($0.id, $0) })
        var finalResults = allResults.filter { $0.statusCode != 429 }
        var rateLimitedIDs = Set(allResults.filter { $0.statusCode == 429 }.map(\.id))

        for attempt in 0..<maxPartRetries {
            guard !rateLimitedIDs.isEmpty else { break }

            Self.logger.warning("Batch: \(rateLimitedIDs.count) parts rate-limited (429), retry \(attempt + 1)/\(maxPartRetries)")
            try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt)))

            let retryRequests = rateLimitedIDs.compactMap { requestsByID[$0] }
            guard !retryRequests.isEmpty else { break }

            let retryResults: [(id: String, statusCode: Int, data: Data)]
            do {
                retryResults = try await performBatch(requests: retryRequests, accessToken: accessToken)
            } catch .unauthorized {
                let fresh = try await refreshAndRetry(accountID: accountID)
                retryResults = try await performBatch(requests: retryRequests, accessToken: fresh.accessToken)
            }

            // Partition retry results into succeeded and still-rate-limited
            rateLimitedIDs = []
            for result in retryResults {
                if result.statusCode == 429 {
                    rateLimitedIDs.insert(result.id)
                } else {
                    finalResults.append(result)
                }
            }
        }

        // Any parts still rate-limited after all retries are returned with 429 status
        if !rateLimitedIDs.isEmpty {
            Self.logger.error("Batch: \(rateLimitedIDs.count) parts still rate-limited after \(maxPartRetries) retries")
            for id in rateLimitedIDs {
                finalResults.append((id: id, statusCode: 429, data: Data()))
            }
        }

        return finalResults
    }

    /// Generic batch fetch: chunks IDs into batches of 50, decodes each successful response.
    /// `pathBuilder` must return full API paths starting with `/gmail/v1/...` (not relative to baseURL).
    /// Runs up to 3 chunks concurrently to reduce latency for large ID sets.
    func batchFetch<T: Decodable & Sendable>(
        ids: [String],
        pathBuilder: @escaping @Sendable (String) -> String,
        accountID: String
    ) async throws(GmailAPIError) -> [T] {
        guard !ids.isEmpty else { return [] }
        let batchSize = 50
        let maxConcurrentBatches = 3

        // Split into chunks of 50
        let chunks: [[String]] = stride(from: 0, to: ids.count, by: batchSize).map { offset in
            Array(ids[offset..<min(offset + batchSize, ids.count)])
        }

        // Single chunk — no TaskGroup overhead needed
        if chunks.count == 1 {
            return try await fetchSingleBatch(chunk: chunks[0], pathBuilder: pathBuilder, accountID: accountID)
        }

        // Multiple chunks — run up to maxConcurrentBatches in parallel.
        // Use non-throwing TaskGroup with Result to satisfy typed throws.
        let (all, firstError): ([T], GmailAPIError?) = await withTaskGroup(of: Result<[T], GmailAPIError>.self) { group in
            var chunkIterator = chunks.makeIterator()
            var collected: [T] = []
            var error: GmailAPIError?

            // Seed initial batch
            for _ in 0..<min(maxConcurrentBatches, chunks.count) {
                if let chunk = chunkIterator.next() {
                    group.addTask {
                        do {
                            let items: [T] = try await self.fetchSingleBatch(chunk: chunk, pathBuilder: pathBuilder, accountID: accountID)
                            return .success(items)
                        } catch let err as GmailAPIError {
                            return .failure(err)
                        } catch {
                            return .failure(.networkError(error))
                        }
                    }
                }
            }

            // As each completes, add the next
            for await result in group {
                switch result {
                case .success(let items):
                    collected.append(contentsOf: items)
                case .failure(let err):
                    if error == nil { error = err }
                }
                if let nextChunk = chunkIterator.next() {
                    group.addTask {
                        do {
                            let items: [T] = try await self.fetchSingleBatch(chunk: nextChunk, pathBuilder: pathBuilder, accountID: accountID)
                            return .success(items)
                        } catch let err as GmailAPIError {
                            return .failure(err)
                        } catch {
                            return .failure(.networkError(error))
                        }
                    }
                }
            }

            return (collected, error)
        }

        // Log warning if some chunks failed but we still have partial results
        if let firstError, !all.isEmpty {
            Self.logger.warning("Batch fetch returned partial results (\(all.count) items). Some chunks failed: \(firstError.localizedDescription)")
        }
        // Only throw if we got zero results AND there was an error
        if let firstError, all.isEmpty {
            throw firstError
        }
        return all
    }

    /// Fetches a single batch of IDs and decodes results.
    @concurrent private func fetchSingleBatch<T: Decodable & Sendable>(
        chunk: [String],
        pathBuilder: @Sendable (String) -> String,
        accountID: String
    ) async throws(GmailAPIError) -> [T] {
        let requests = chunk.map { id in
            (id: id, method: "GET", path: pathBuilder(id), body: nil as Data?)
        }
        let results = try await batchRequest(requests: requests, accountID: accountID)
        let decoder = JSONDecoder()
        var items: [T] = []
        for result in results {
            guard (200...299).contains(result.statusCode) else {
                Self.logger.warning("Batch part \(result.id) failed: HTTP \(result.statusCode)")
                continue
            }
            do {
                let item = try decoder.decode(T.self, from: result.data)
                items.append(item)
            } catch {
                Self.logger.error("Batch decode failed for \(result.id): \(error.localizedDescription)")
            }
        }
        return items
    }

    // MARK: - Perform for arbitrary Google API URLs

    /// Executes an authenticated GET to any full URL (not limited to Gmail base URL).
    @concurrent private func performURL(
        _ urlString: String,
        accessToken: String
    ) async throws(GmailAPIError) -> Data {
        guard let url = URL(string: urlString) else { throw .invalidURL }

        for attempt in 0...RetryPolicy.maxRetries {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("Serif/1.0 (gzip)", forHTTPHeaderField: "User-Agent")
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await Self.session.data(for: request)
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
            case 403 where RetryPolicy.isRateLimited403(data) && attempt < RetryPolicy.maxRetries:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt, retryAfter: retryAfter)))
                continue
            case 403:
                if let body = String(data: data, encoding: .utf8) {
                    if body.contains("dailyLimitExceeded") { throw .dailyLimitExceeded }
                    if body.contains("domainPolicy") { throw .domainPolicy }
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
                part += bodyStr + "\r\n"
            } else {
                part += "\r\n"
            }
            bodyParts.append(part)
        }

        let fullBody = bodyParts.joined() + "--\(boundary)--"
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
                (data, response) = try await Self.session.data(for: urlRequest)
            } catch {
                if RetryPolicy.isRetriableNetworkError(error), attempt < RetryPolicy.maxRetries {
                    try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt)))
                    continue
                }
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
            case 403 where RetryPolicy.isRateLimited403(data) && attempt < RetryPolicy.maxRetries:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt, retryAfter: retryAfter)))
                continue
            case 403:
                if let body = String(data: data, encoding: .utf8) {
                    if body.contains("dailyLimitExceeded") { throw .dailyLimitExceeded }
                    if body.contains("domainPolicy") { throw .domainPolicy }
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
            if contentID.hasPrefix("response-") {
                contentID = String(contentID.dropFirst(9))
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
    /// If a refresh is already in flight, awaits it instead of starting a new one
    /// (avoids double-refresh when concurrent 401s race).
    private func refreshAndRetry(accountID: String) async throws(GmailAPIError) -> AuthToken {
        if let existing = refreshTasks[accountID] {
            do {
                return try await existing.value
            } catch {
                throw .wrap(error)
            }
        }
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

        let generation = (refreshGeneration[accountID] ?? 0) + 1
        refreshGeneration[accountID] = generation

        let task = Task<AuthToken, Error> {
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
            let result = try await task.value
            // Only clear if this is still our task (generation matches)
            if refreshGeneration[accountID] == generation {
                refreshTasks[accountID] = nil
                refreshGeneration.removeValue(forKey: accountID)
            }
            return result
        } catch {
            if refreshGeneration[accountID] == generation {
                refreshTasks[accountID] = nil
                refreshGeneration.removeValue(forKey: accountID)
            }
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
                Self.logger.debug("Compression: \(encoding) for \(path)")
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
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            request.httpBody = body

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await Self.session.data(for: request)
            } catch {
                if RetryPolicy.isRetriableNetworkError(error), attempt < RetryPolicy.maxRetries {
                    try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt)))
                    continue
                }
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
            case 403 where RetryPolicy.isRateLimited403(data) && attempt < RetryPolicy.maxRetries:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt, retryAfter: retryAfter)))
                continue
            case 403:
                if let body = String(data: data, encoding: .utf8) {
                    if body.contains("dailyLimitExceeded") { throw .dailyLimitExceeded }
                    if body.contains("domainPolicy") { throw .domainPolicy }
                }
                throw .httpError(http.statusCode, data)
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
    case dailyLimitExceeded
    case domainPolicy

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
        case .dailyLimitExceeded:              return "Gmail daily API limit exceeded — try again tomorrow"
        case .domainPolicy:                    return "Blocked by domain policy — contact your administrator"
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

    /// Returns true if a 403 response body contains a Google rate-limit reason
    /// (`rateLimitExceeded` or `userRateLimitExceeded`), which should be retried.
    static func isRateLimited403(_ data: Data) -> Bool {
        guard let body = String(data: data, encoding: .utf8) else { return false }
        return body.contains("rateLimitExceeded") || body.contains("userRateLimitExceeded")
    }

    /// Returns true for transient network errors worth retrying (timeout, connection lost, etc.).
    static func isRetriableNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorSecureConnectionFailed:
            return true
        default:
            return false
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
        return min(base + jitter, 32.0)
    }
}

// MARK: - Path Builder

enum GmailPathBuilder {
    /// Query-safe characters — `.urlQueryAllowed` minus `+` (which means space in query strings).
    static let queryAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove("+")
        return cs
    }()

    /// Path-safe characters — `.urlPathAllowed` minus `+` (ambiguous in email addresses).
    private static let pathAllowed: CharacterSet = {
        var cs = CharacterSet.urlPathAllowed
        cs.remove("+")
        return cs
    }()

    /// Builds a single `&labelIds=...` query parameter with URL encoding.
    static func labelQueryParam(_ labelID: String) -> String {
        let encoded = labelID.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? labelID
        return "&labelIds=\(encoded)"
    }

    /// Builds the path for a sendAs endpoint with URL-encoded email.
    static func sendAsPath(_ email: String) -> String {
        let encoded = email.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? email
        return "/users/me/settings/sendAs/\(encoded)"
    }
}
