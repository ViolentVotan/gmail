import Foundation
import os.log
import Synchronization

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the Gmail API returns 403 `insufficientPermissions`.
    /// `userInfo` contains `[GmailAPIClient.accountIDKey: String]`.
    static let gmailScopesInsufficient = Notification.Name("GmailAPIClient.gmailScopesInsufficient")
}

/// Result of a batch fetch containing successfully decoded items and IDs that failed.
/// Failed IDs can be retried on a subsequent sync cycle by the caller.
struct BatchFetchResult<T: Sendable>: Sendable {
    let items: [T]
    let failedIDs: [String]
}

/// Base HTTP client for all Gmail API requests.
/// Automatically refreshes expired tokens before each call.
@MainActor
final class GmailAPIClient {
    static let shared = GmailAPIClient()
    private init() {}

    /// Key for the account ID in `gmailScopesInsufficient` notification's userInfo.
    nonisolated static let accountIDKey = "accountID"

    nonisolated private static let jsonDecoder = JSONDecoder()

    private let baseURL = "https://gmail.googleapis.com/gmail/v1"
    nonisolated private static let logger = Logger(category: "GmailAPI")
    private var refreshTasks: [String: Task<AuthToken, Error>] = [:]
    private var refreshGeneration: [String: Int] = [:]

    /// Thread-safe cache of last-known valid tokens keyed by account ID.
    private nonisolated let cachedTokens = Mutex<[String: AuthToken]>([:])

    /// Configured session for Google API calls: appropriate timeouts,
    /// connection pooling, and connectivity waiting.
    /// Exposed as `internal` so services like `GmailProfileService` can reuse
    /// the same session instead of duplicating the configuration.
    nonisolated static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    nonisolated private static let userAgent = "Vik/1.0 (gzip)"

    // MARK: - Shared request helpers

    /// Applies the three standard HTTP headers to every outbound request.
    private nonisolated static func applyCommonHeaders(to request: inout URLRequest, accessToken: String) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    }

    /// Classifies a 403 response body and returns the matching error.
    /// Posts the `gmailScopesInsufficient` notification when `insufficientPermissions`
    /// is detected and an `accountID` is available.
    private nonisolated static func classify403(data: Data, accountID: String?) -> GmailAPIError {
        guard let body = String(data: data, encoding: .utf8) else {
            return .httpError(403, data)
        }
        if body.contains("dailyLimitExceeded") { return .dailyLimitExceeded }
        if body.contains("domainPolicy") { return .domainPolicy }
        if body.contains("insufficientPermissions") {
            if let accountID {
                NotificationCenter.default.post(
                    name: .gmailScopesInsufficient,
                    object: nil,
                    userInfo: [GmailAPIClient.accountIDKey: accountID]
                )
            }
            return .insufficientPermissions
        }
        return .httpError(403, data)
    }

    // MARK: - Decoded requests

    @concurrent func request<T: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        fields: String? = nil,
        accountID: String
    ) async throws(GmailAPIError) -> T {
        let data = try await rawRequest(path: path, method: method, body: body, contentType: contentType, fields: fields, accountID: accountID)
        do {
            return try Self.jsonDecoder.decode(T.self, from: data)
        } catch {
            throw .decodingError(error)
        }
    }

    /// Returns raw Data (e.g. for DELETE responses or binary payloads).
    @concurrent func rawRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        fields: String? = nil,
        accountID: String
    ) async throws(GmailAPIError) -> Data {
        guard NetworkMonitor.isReachable else { throw .offline }
        let token = try await cachedValidToken(for: accountID)

        // First attempt + 401 auto-retry
        do {
            return try await doPerform(path: path, method: method, body: body, contentType: contentType, fields: fields, accessToken: token.accessToken, accountID: accountID)
        } catch .unauthorized {
            let fresh = try await refreshAndRetry(accountID: accountID)
            return try await doPerform(path: path, method: method, body: body, contentType: contentType, fields: fields, accessToken: fresh.accessToken, accountID: accountID)
        }
    }

    // MARK: - Resumable upload

    /// Sends a message via Gmail's resumable upload protocol.
    /// Use for MIME payloads >5 MB where inline base64url encoding is impractical.
    ///
    /// Two-step process:
    /// 1. POST to initiate the upload — server returns a resumable upload URI.
    /// 2. PUT the raw MIME data to that URI — server returns the created `GmailMessage`.
    @concurrent func uploadResumable(
        mimeData: Data,
        threadID: String?,
        accountID: String
    ) async throws(GmailAPIError) -> GmailMessage {
        guard NetworkMonitor.isReachable else { throw .offline }
        let token = try await cachedValidToken(for: accountID)

        do {
            return try await doUploadResumable(mimeData: mimeData, threadID: threadID, accessToken: token.accessToken)
        } catch .unauthorized {
            let fresh = try await refreshAndRetry(accountID: accountID)
            return try await doUploadResumable(mimeData: mimeData, threadID: threadID, accessToken: fresh.accessToken)
        }
    }

    /// Performs the two-step resumable upload with retry logic.
    @concurrent private func doUploadResumable(
        mimeData: Data,
        threadID: String?,
        accessToken: String
    ) async throws(GmailAPIError) -> GmailMessage {
        // Step 1: Initiate the resumable upload session
        let uploadURI = try await initiateResumableUpload(
            mimeData: mimeData, threadID: threadID, accessToken: accessToken
        )

        // Step 2: PUT the raw MIME data to the upload URI
        return try await putResumableData(mimeData: mimeData, uploadURI: uploadURI)
    }

    /// Initiates a resumable upload session, returning the upload URI from the `Location` header.
    @concurrent private func initiateResumableUpload(
        mimeData: Data,
        threadID: String?,
        accessToken: String
    ) async throws(GmailAPIError) -> URL {
        let endpoint = "https://www.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=resumable"
        guard let url = URL(string: endpoint) else { throw .invalidURL }

        var metadata: [String: String] = [:]
        if let threadID { metadata["threadId"] = threadID }
        let metadataBody: Data
        do {
            metadataBody = try JSONSerialization.data(withJSONObject: metadata)
        } catch {
            throw .encodingError(error)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        Self.applyCommonHeaders(to: &request, accessToken: accessToken)
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("message/rfc822", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue("\(mimeData.count)", forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = metadataBody

        let (data, http) = try await Self.retryingRequest(request)

        switch http.statusCode {
        case 200...299:
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let uri = URL(string: location) else {
                throw .httpError(http.statusCode, data)
            }
            return uri
        case 401:
            throw .unauthorized
        default:
            throw .httpError(http.statusCode, data)
        }
    }

    /// Uploads raw MIME data to the resumable upload URI, returning the created message.
    @concurrent private func putResumableData(
        mimeData: Data,
        uploadURI: URL
    ) async throws(GmailAPIError) -> GmailMessage {
        var request = URLRequest(url: uploadURI)
        request.httpMethod = "PUT"
        request.setValue("message/rfc822", forHTTPHeaderField: "Content-Type")
        request.setValue("\(mimeData.count)", forHTTPHeaderField: "Content-Length")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = mimeData

        let (responseData, http) = try await Self.retryingRequest(request)

        switch http.statusCode {
        case 200...299:
            do {
                return try Self.jsonDecoder.decode(GmailMessage.self, from: responseData)
            } catch {
                throw .decodingError(error)
            }
        case 401:
            throw .unauthorized
        default:
            throw .httpError(http.statusCode, responseData)
        }
    }

    // MARK: - ETag-aware request

    /// Makes a GET request with optional `If-None-Match` header for cache validation.
    /// Returns `nil` when the server responds with 304 Not Modified.
    /// Returns `(decoded, etag)` on 200, where `etag` is the ETag header value if present.
    @concurrent func requestWithETag<T: Decodable>(
        path: String,
        etag: String?,
        fields: String? = nil,
        accountID: String
    ) async throws(GmailAPIError) -> (T, String?)? {
        guard NetworkMonitor.isReachable else { throw .offline }
        let token = try await cachedValidToken(for: accountID)

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
        Self.appendFields(fields, to: &fullPath)
        guard let url = URL(string: baseURL + fullPath) else { throw .invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        Self.applyCommonHeaders(to: &request, accessToken: accessToken)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, http) = try await Self.retryingRequest(request)

        switch http.statusCode {
        case 304:
            return nil
        case 200...299:
            let responseETag = http.value(forHTTPHeaderField: "ETag")
                ?? http.value(forHTTPHeaderField: "Etag")
            do {
                let decoded = try Self.jsonDecoder.decode(T.self, from: data)
                return (decoded, responseETag)
            } catch {
                throw .decodingError(error)
            }
        case 401:
            throw .unauthorized
        case 403:
            throw Self.classify403(data: data, accountID: nil)
        default:
            throw .httpError(http.statusCode, data)
        }
    }

    // MARK: - Authenticated request to any Google API URL

    /// Makes an authenticated GET request to any Google API (not limited to the Gmail base URL).
    @concurrent func requestURL<T: Decodable>(_ urlString: String, accountID: String) async throws(GmailAPIError) -> T {
        guard NetworkMonitor.isReachable else { throw .offline }
        let token = try await cachedValidToken(for: accountID)

        let doRequest = { (accessToken: String) async throws(GmailAPIError) -> T in
            let data = try await self.performURL(urlString, accessToken: accessToken)
            do {
                return try Self.jsonDecoder.decode(T.self, from: data)
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
    @concurrent func batchRequest(
        requests: [(id: String, method: String, path: String, body: Data?)],
        accountID: String
    ) async throws(GmailAPIError) -> [(id: String, statusCode: Int, data: Data)] {
        guard NetworkMonitor.isReachable else { throw .offline }
        let token = try await cachedValidToken(for: accountID)
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
    @concurrent private func retryRateLimitedParts(
        allResults: [(id: String, statusCode: Int, data: Data)],
        originalRequests: [(id: String, method: String, path: String, body: Data?)],
        accessToken: String,
        accountID: String
    ) async throws(GmailAPIError) -> [(id: String, statusCode: Int, data: Data)] {
        let maxPartRetries = 3
        let requestsByID = Dictionary(uniqueKeysWithValues: originalRequests.map { ($0.id, $0) })
        var finalResults = allResults.filter { $0.statusCode != 429 }
        var rateLimitedIDs = Set(allResults.filter { $0.statusCode == 429 }.map(\.id))
        var activeToken = accessToken

        for attempt in 0..<maxPartRetries {
            guard !rateLimitedIDs.isEmpty else { break }

            Self.logger.warning("Batch: \(rateLimitedIDs.count) parts rate-limited (429), retry \(attempt + 1)/\(maxPartRetries)")
            try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt)))

            let retryRequests = rateLimitedIDs.compactMap { requestsByID[$0] }
            guard !retryRequests.isEmpty else { break }

            let retryResults: [(id: String, statusCode: Int, data: Data)]
            do {
                retryResults = try await performBatch(requests: retryRequests, accessToken: activeToken)
            } catch .unauthorized {
                let fresh = try await refreshAndRetry(accountID: accountID)
                activeToken = fresh.accessToken
                retryResults = try await performBatch(requests: retryRequests, accessToken: activeToken)
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
    /// Returns successfully decoded items and IDs that failed — callers should retry failed IDs
    /// on a subsequent sync cycle rather than inline.
    @concurrent func batchFetch<T: Decodable & Sendable>(
        ids: [String],
        pathBuilder: @escaping @Sendable (String) -> String,
        accountID: String
    ) async throws(GmailAPIError) -> BatchFetchResult<T> {
        guard !ids.isEmpty else { return BatchFetchResult(items: [], failedIDs: []) }
        let batchSize = 50
        // Reduced from 3 to 2 to avoid hitting Gmail's undocumented per-user
        // concurrent request limit (50×3=150 in-flight parts can trigger 429s).
        let maxConcurrentBatches = 2

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
        // Track which chunk indices failed for logging.
        let (allItems, allFailedIDs, firstError, failedChunkCount): ([T], [String], GmailAPIError?, Int) = await withTaskGroup(of: (Int, Result<BatchFetchResult<T>, GmailAPIError>).self) { group in
            var chunkIterator = chunks.enumerated().makeIterator()
            var collected: [T] = []
            var failedIDs: [String] = []
            var error: GmailAPIError?
            var failedChunks = 0

            // Seed initial batch
            for _ in 0..<min(maxConcurrentBatches, chunks.count) {
                if let (index, chunk) = chunkIterator.next() {
                    group.addTask {
                        do {
                            let result: BatchFetchResult<T> = try await self.fetchSingleBatch(chunk: chunk, pathBuilder: pathBuilder, accountID: accountID)
                            return (index, .success(result))
                        } catch let err as GmailAPIError {
                            return (index, .failure(err))
                        } catch {
                            return (index, .failure(.networkError(error)))
                        }
                    }
                }
            }

            // As each completes, add the next
            for await (chunkIndex, result) in group {
                switch result {
                case .success(let batchResult):
                    collected.append(contentsOf: batchResult.items)
                    failedIDs.append(contentsOf: batchResult.failedIDs)
                case .failure(let err):
                    failedChunks += 1
                    // All IDs in the failed chunk are considered failed
                    failedIDs.append(contentsOf: chunks[chunkIndex])
                    Self.logger.error("Batch fetch chunk \(chunkIndex) failed (\(chunks[chunkIndex].count) IDs): \(err.localizedDescription)")
                    if error == nil { error = err }
                }
                if let (nextIndex, nextChunk) = chunkIterator.next() {
                    group.addTask {
                        do {
                            let result: BatchFetchResult<T> = try await self.fetchSingleBatch(chunk: nextChunk, pathBuilder: pathBuilder, accountID: accountID)
                            return (nextIndex, .success(result))
                        } catch let err as GmailAPIError {
                            return (nextIndex, .failure(err))
                        } catch {
                            return (nextIndex, .failure(.networkError(error)))
                        }
                    }
                }
            }

            return (collected, failedIDs, error, failedChunks)
        }

        // Log warning if some chunks failed but we still have partial results
        if let firstError, !allItems.isEmpty {
            Self.logger.warning("Batch fetch returned partial results (\(allItems.count) items). \(failedChunkCount) chunk(s) failed: \(firstError.localizedDescription)")
        }
        // Only throw if we got zero results AND there was an error
        if let firstError, allItems.isEmpty {
            throw firstError
        }
        if !allFailedIDs.isEmpty {
            Self.logger.warning("Batch fetch: \(allFailedIDs.count) IDs failed (will be retried on next sync)")
        }
        return BatchFetchResult(items: allItems, failedIDs: allFailedIDs)
    }

    /// Fetches a single batch of IDs and decodes results.
    /// Returns successfully decoded items and IDs that failed (non-2xx or decode error).
    @concurrent private func fetchSingleBatch<T: Decodable & Sendable>(
        chunk: [String],
        pathBuilder: @Sendable (String) -> String,
        accountID: String
    ) async throws(GmailAPIError) -> BatchFetchResult<T> {
        let requests = chunk.map { id in
            (id: id, method: "GET", path: pathBuilder(id), body: nil as Data?)
        }
        let results = try await batchRequest(requests: requests, accountID: accountID)
        var items: [T] = []
        var failedIDs: [String] = []
        for result in results {
            guard (200...299).contains(result.statusCode) else {
                Self.logger.warning("Batch part \(result.id) failed: HTTP \(result.statusCode)")
                failedIDs.append(result.id)
                continue
            }
            do {
                let item = try Self.jsonDecoder.decode(T.self, from: result.data)
                items.append(item)
            } catch {
                Self.logger.error("Batch decode failed for \(result.id): \(error.localizedDescription)")
                failedIDs.append(result.id)
            }
        }
        return BatchFetchResult(items: items, failedIDs: failedIDs)
    }

    // MARK: - Pre-auth request (raw token)

    /// Executes an authenticated GET request using a raw access token, with full
    /// retry logic. Intended for pre-sign-in flows (e.g. fetching user info)
    /// where no account ID is available yet.
    @concurrent nonisolated static func requestWithToken<T: Decodable>(
        url urlString: String,
        token: String
    ) async throws(GmailAPIError) -> T {
        guard let url = URL(string: urlString) else { throw .invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, accessToken: token)

        let (data, http) = try await retryingRequest(request)

        switch http.statusCode {
        case 200...299:
            do {
                return try Self.jsonDecoder.decode(T.self, from: data)
            } catch {
                throw .decodingError(error)
            }
        case 401:
            throw .unauthorized
        case 403:
            throw classify403(data: data, accountID: nil)
        default:
            throw .httpError(http.statusCode, data)
        }
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
        Self.applyCommonHeaders(to: &request, accessToken: accessToken)

        let (data, http) = try await Self.retryingRequest(request)

        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw .unauthorized
        case 403:
            throw Self.classify403(data: data, accountID: nil)
        default:
            throw .httpError(http.statusCode, data)
        }
    }

    /// Executes batch HTTP call off the main actor with retry logic matching `perform()`.
    @concurrent private func performBatch(
        requests: [(id: String, method: String, path: String, body: Data?)],
        accessToken: String
    ) async throws(GmailAPIError) -> [(id: String, statusCode: Int, data: Data)] {
        let boundary = "batch_vik_\(UUID().uuidString)"
        var bodyParts: [String] = []

        for req in requests {
            var part = "--\(boundary)\r\n"
            part += "Content-Type: application/http\r\n"
            part += "Content-ID: <\(req.id)>\r\n\r\n"
            part += "\(req.method) \(req.path) HTTP/1.1\r\n"
            if let bodyData = req.body, let bodyStr = String(data: bodyData, encoding: .utf8) {
                part += "Content-Type: application/json\r\n"
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

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        Self.applyCommonHeaders(to: &urlRequest, accessToken: accessToken)
        urlRequest.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        let (data, http) = try await Self.retryingRequest(urlRequest)

        switch http.statusCode {
        case 200...299:
            guard let contentType = http.value(forHTTPHeaderField: "Content-Type"),
                  let responseBoundary = contentType.components(separatedBy: "boundary=").last?.trimmingCharacters(in: .whitespaces) else {
                throw .decodingError(URLError(.cannotParseResponse))
            }
            return try Self.parseBatchResponse(data: data, boundary: responseBoundary)
        case 401:
            throw .unauthorized
        case 403:
            throw Self.classify403(data: data, accountID: nil)
        default:
            throw .httpError(http.statusCode, data)
        }
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

            // Extract Content-ID (case-insensitive per RFC 7230)
            var contentID = ""
            if let idRange = trimmed.range(of: "Content-ID: <", options: .caseInsensitive) {
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

    /// Fast path: returns the cached token if still valid.
    /// On cache miss, falls back to `validToken(for:)` which reads Keychain off MainActor.
    @concurrent private func cachedValidToken(for accountID: String) async throws(GmailAPIError) -> AuthToken {
        if let cached = cachedTokens.withLock({ $0[accountID] }), !cached.isExpired {
            return cached
        }
        return try await validToken(for: accountID)
    }

    @concurrent private func validToken(for accountID: String) async throws(GmailAPIError) -> AuthToken {
        let token: AuthToken?
        do {
            token = try await TokenStore.shared.retrieve(for: accountID)
        } catch {
            throw .networkError(error)
        }
        guard let token else { throw .unauthorized }
        guard token.isExpired else {
            cachedTokens.withLock { $0[accountID] = token }
            return token
        }
        return try await refreshAndRetry(accountID: accountID)
    }

    /// Forces a token refresh (invalidates cached token). Used for 401 auto-retry.
    /// If a refresh is already in flight, awaits it instead of starting a new one
    /// (avoids double-refresh when concurrent 401s race).
    @concurrent private func refreshAndRetry(accountID: String) async throws(GmailAPIError) -> AuthToken {
        // Single atomic check-or-create on MainActor — prevents TOCTOU race
        // where two concurrent callers both see nil and create duplicate refresh tasks.
        let (task, isNew): (Task<AuthToken, Error>, Bool) = await MainActor.run {
            if let existing = refreshTasks[accountID] {
                return (existing, false)
            }
            let generation = (refreshGeneration[accountID] ?? 0) + 1
            refreshGeneration[accountID] = generation

            // Use Task.detached to avoid inheriting MainActor isolation —
            // the body does network I/O that should not occupy the main actor.
            let t = Task.detached { [self] in
                await MainActor.run { self.refreshTasks[accountID] = nil }
                let token: AuthToken?
                do {
                    token = try await TokenStore.shared.retrieve(for: accountID)
                } catch {
                    throw GmailAPIError.networkError(error)
                }
                guard let token else { throw GmailAPIError.unauthorized }
                let fresh = try await OAuthService.shared.refreshToken(token)
                try await TokenStore.shared.save(fresh, for: accountID)
                return fresh
            }
            refreshTasks[accountID] = t
            return (t, true)
        }

        do {
            let result = try await task.value
            if isNew {
                await MainActor.run { _ = refreshGeneration.removeValue(forKey: accountID) }
                cachedTokens.withLock { $0[accountID] = result }
            }
            return result
        } catch {
            if isNew {
                await MainActor.run { _ = refreshGeneration.removeValue(forKey: accountID) }
                // Clear revoked tokens from Keychain so we don't retry stale credentials on next launch
                if case .tokenRevoked = error as? OAuthError {
                    await TokenStore.shared.delete(for: accountID)
                    _ = cachedTokens.withLock { $0.removeValue(forKey: accountID) }
                }
            }
            throw .wrap(error)
        }
    }

    // MARK: - Perform with logging

    /// Wraps `perform()` with DEBUG logging. Extracted to allow 401 retry without duplicating logic.
    @concurrent private func doPerform(
        path: String,
        method: String,
        body: Data?,
        contentType: String?,
        fields: String?,
        accessToken: String,
        accountID: String
    ) async throws(GmailAPIError) -> Data {
        #if DEBUG
        let reqHeaders: [String: String] = {
            var h = ["Authorization": "Bearer [hidden]"]
            if let ct = contentType { h["Content-Type"] = ct }
            return h
        }()
        let reqBody: String? = if method == "POST" && (path.contains("/messages/send") || path.contains("/drafts/send")) {
            "[email body redacted]"
        } else {
            body.flatMap { String(data: $0, encoding: .utf8) }
        }
        let t0 = Date()
        do {
            let (data, code, respHeaders) = try await perform(path: path, method: method, body: body, contentType: contentType, fields: fields, accessToken: accessToken, accountID: accountID)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            await APILogger.shared.log(APILogEntry(
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
                await APILogger.shared.log(APILogEntry(
                    method: method, path: path, statusCode: code, errorMessage: "HTTP \(code)",
                    requestHeaders: reqHeaders, requestBody: reqBody,
                    responseBodyData: errData, responseSize: errData.count, durationMs: ms, fromCache: false
                ))
            } else {
                await APILogger.shared.log(APILogEntry(
                    method: method, path: path, statusCode: nil, errorMessage: error.localizedDescription,
                    requestHeaders: reqHeaders, requestBody: reqBody,
                    responseBodyData: Data(), responseSize: 0, durationMs: ms, fromCache: false
                ))
            }
            throw error
        }
        #else
        let (data, _, _) = try await perform(path: path, method: method, body: body, contentType: contentType, fields: fields, accessToken: accessToken, accountID: accountID)
        return data
        #endif
    }

    // MARK: - Query helpers

    nonisolated private static func appendFields(_ fields: String?, to path: inout String) {
        guard let fields else { return }
        let separator = path.contains("?") ? "&" : "?"
        let encoded = fields.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fields
        path += "\(separator)fields=\(encoded)"
    }

    // MARK: - HTTP layer

    /// Low-level retry loop handling network errors, retriable status codes (5xx),
    /// 429 rate-limiting, and 403 rate-limiting. Returns the raw response — callers
    /// handle status-specific logic (401, 304, success parsing, non-rate-limit 403s).
    @concurrent private nonisolated static func retryingRequest(
        _ request: URLRequest
    ) async throws(GmailAPIError) -> (Data, HTTPURLResponse) {
        do {
            return try await RetryPolicy.retryingHTTP {
                try await sharedSession.data(for: request)
            }
        } catch {
            throw GmailAPIError.wrap(error)
        }
    }

    /// Returns (data, httpStatusCode, responseHeaders).
    @concurrent private func perform(
        path: String,
        method: String,
        body: Data?,
        contentType: String?,
        fields: String?,
        accessToken: String,
        accountID: String
    ) async throws(GmailAPIError) -> (Data, Int, [String: String]) {
        var fullPath = path
        Self.appendFields(fields, to: &fullPath)
        guard let url = URL(string: baseURL + fullPath) else { throw .invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        Self.applyCommonHeaders(to: &request, accessToken: accessToken)
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        let (data, http) = try await Self.retryingRequest(request)

        let responseHeaders = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let val = pair.value as? String { result[key] = val }
        }

        switch http.statusCode {
        case 200...299:
            return (data, http.statusCode, responseHeaders)
        case 401:
            throw .unauthorized
        case 403:
            throw Self.classify403(data: data, accountID: accountID)
        default:
            throw .httpError(http.statusCode, data)
        }
    }

    // MARK: - Calendar token bridge

    /// Returns a valid cached or refreshed token for use by `CalendarAPIClient`.
    /// Avoids duplicating token infrastructure — Calendar delegates auth here.
    func validCalendarToken(for accountID: String) async throws(GmailAPIError) -> AuthToken {
        try await cachedValidToken(for: accountID)
    }

    /// Forces a token refresh for use by `CalendarAPIClient` on 401.
    func refreshCalendarToken(for accountID: String) async throws(GmailAPIError) -> AuthToken {
        try await refreshAndRetry(accountID: accountID)
    }

}

// MARK: - Errors

enum GmailAPIError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case offline
    case tokenRevoked
    case httpError(Int, Data)
    case decodingError(Error)
    case encodingError(Error)
    case partialFailure(failedCount: Int)
    case networkError(Error)
    case attachmentReadFailed([String])
    case dailyLimitExceeded
    case domainPolicy
    case insufficientPermissions

    var errorDescription: String? {
        switch self {
        case .invalidURL:                      return "Invalid API URL"
        case .unauthorized:                    return "Unauthorized — please sign in again"
        case .offline:                         return "You're offline — please check your connection"
        case .tokenRevoked:                    return "Session expired — please sign in again"
        case .httpError(let c, _):             return "HTTP \(c)"
        case .decodingError(let e):            return "Decode failed: \(e.localizedDescription)"
        case .encodingError(let e):            return "Encode failed: \(e.localizedDescription)"
        case .partialFailure(let count):       return "Failed to delete \(count) messages"
        case .networkError(let e):             return "Network error: \(e.localizedDescription)"
        case .attachmentReadFailed(let names): return "Could not read attachments: \(names.joined(separator: ", "))"
        case .dailyLimitExceeded:              return "Gmail daily API limit exceeded — try again tomorrow"
        case .domainPolicy:                    return "Blocked by domain policy — contact your administrator"
        case .insufficientPermissions:         return "Insufficient permissions — please reauthorize Gmail access"
        }
    }

    /// Wraps an arbitrary error into a `GmailAPIError`, passing through if already one.
    /// Maps `OAuthError.tokenRevoked` to `.tokenRevoked` so callers get a clear signal.
    static func wrap(_ error: Error) -> GmailAPIError {
        if let apiError = error as? GmailAPIError { return apiError }
        if let oauthError = error as? OAuthError {
            switch oauthError {
            case .tokenRevoked, .noRefreshToken: return .tokenRevoked
            default: break
            }
        }
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
        let jitter = Double.random(in: 0...1.0)
        return min(base + jitter, 64.0)
    }

    /// Shared HTTP retry loop handling network errors, retriable status codes (5xx),
    /// 429 rate-limiting, and 403 rate-limiting. Returns the raw response — callers
    /// handle domain-specific status codes (401, 409, 410, success parsing, etc.).
    ///
    /// - Parameter execute: Closure that performs the actual HTTP request.
    /// - Throws: The `Error` produced by the closure on non-retriable failure,
    ///   or a generic error if retries are exhausted. Callers map to their typed error.
    static func retryingHTTP(
        _ execute: () async throws -> (Data, URLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...maxRetries {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await execute()
            } catch {
                if isRetriableNetworkError(error), attempt < maxRetries {
                    try? await Task.sleep(for: .seconds(delay(forAttempt: attempt)))
                    continue
                }
                throw error
            }
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            // Handle 429 with backoff
            if http.statusCode == 429, attempt < maxRetries {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                try? await Task.sleep(for: .seconds(delay(forAttempt: attempt, retryAfter: retryAfter)))
                continue
            }

            // Handle 403 rate-limiting (needs body check)
            if http.statusCode == 403, isRateLimited403(data), attempt < maxRetries {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                try? await Task.sleep(for: .seconds(delay(forAttempt: attempt, retryAfter: retryAfter)))
                continue
            }

            // Handle other retriable status codes (5xx)
            if isRetriable(statusCode: http.statusCode), attempt < maxRetries {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                // Intentionally use try? — if task is cancelled, the next iteration's
                // URLSession call will throw, which the caller converts to its error type.
                try? await Task.sleep(for: .seconds(delay(forAttempt: attempt, retryAfter: retryAfter)))
                continue
            }

            // All other statuses: return to caller for handling
            return (data, http)
        }
        throw URLError(.timedOut)
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
