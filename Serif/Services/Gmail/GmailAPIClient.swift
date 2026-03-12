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
        accountID: String
    ) async throws(GmailAPIError) -> T {
        let data = try await rawRequest(path: path, method: method, body: body, contentType: contentType, accountID: accountID)
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
        accountID: String
    ) async throws(GmailAPIError) -> Data {
        guard NetworkMonitor.shared.isConnected else { throw .offline }
        let token = try await validToken(for: accountID)

        #if DEBUG
        let reqHeaders: [String: String] = {
            var h = ["Authorization": "Bearer [hidden]"]
            if let ct = contentType { h["Content-Type"] = ct }
            return h
        }()
        let reqBody: String? = body.flatMap { String(data: $0, encoding: .utf8) }
        let t0 = Date()
        do {
            let (data, code, respHeaders) = try await perform(path: path, method: method, body: body, contentType: contentType, accessToken: token.accessToken)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            APILogger.shared.log(APILogEntry(
                method: method, path: path, statusCode: code, errorMessage: nil,
                requestHeaders: reqHeaders, requestBody: reqBody,
                responseHeaders: respHeaders,
                responseBodyData: data, responseSize: data.count, durationMs: ms, fromCache: false
            ))
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
        let (data, _, _) = try await perform(path: path, method: method, body: body, contentType: contentType, accessToken: token.accessToken)
        return data
        #endif
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

    // MARK: - HTTP layer

    /// Returns (data, httpStatusCode, responseHeaders).
    @concurrent private func perform(
        path: String,
        method: String,
        body: Data?,
        contentType: String?,
        accessToken: String
    ) async throws(GmailAPIError) -> (Data, Int, [String: String]) {
        guard let url = URL(string: baseURL + path) else { throw .invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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
        case 200...299: return (data, http.statusCode, headers)
        case 401:       throw .unauthorized
        default:        throw .httpError(http.statusCode, data)
        }
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
