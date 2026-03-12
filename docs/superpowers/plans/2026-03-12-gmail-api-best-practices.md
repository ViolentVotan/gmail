# Gmail & People API Best Practices Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align the Serif Gmail client's API layer with official Google API best practices — retry logic, DRY, SOLID, URL safety, and partial responses.

**Architecture:** Add retry-with-backoff to `GmailAPIClient`, extract debug logging into a helper, split `GmailProfileService` into Gmail-scoped and People API-scoped services, switch draft batch fetch to use the batch API, add missing `fields` parameters, and fix URL-encoding gaps.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing, macOS 26+

---

## Chunk 1: GmailAPIClient Reliability & DRY

### Task 1: Add Retry with Exponential Backoff to GmailAPIClient

**Files:**
- Modify: `Serif/Services/Gmail/GmailAPIClient.swift`
- Create: `SerifTests/GmailAPIClientRetryTests.swift`

Google's official Gmail API docs require retrying on 429 (rate limit), 503 (service unavailable), and 500 (internal server error) with exponential backoff starting at 1 second. Also retry once on 401 after refreshing the token.

- [ ] **Step 1: Write failing tests for retry logic**

Create `SerifTests/GmailAPIClientRetryTests.swift`:

```swift
import Testing
import Foundation
@testable import Serif

@Suite struct RetryDelayTests {

    @Test func firstRetryDelayIsOneSecond() {
        let delay = RetryPolicy.delay(forAttempt: 0)
        #expect(delay >= 1.0 && delay <= 1.5) // 1s base + up to 0.5s jitter
    }

    @Test func secondRetryDelayIsAboutTwoSeconds() {
        let delay = RetryPolicy.delay(forAttempt: 1)
        #expect(delay >= 2.0 && delay <= 3.0) // 2s base + jitter
    }

    @Test func thirdRetryDelayIsAboutFourSeconds() {
        let delay = RetryPolicy.delay(forAttempt: 2)
        #expect(delay >= 4.0 && delay <= 6.0)
    }

    @Test func retriableStatusCodes() {
        #expect(RetryPolicy.isRetriable(statusCode: 429) == true)
        #expect(RetryPolicy.isRetriable(statusCode: 500) == true)
        #expect(RetryPolicy.isRetriable(statusCode: 503) == true)
        #expect(RetryPolicy.isRetriable(statusCode: 400) == false)
        #expect(RetryPolicy.isRetriable(statusCode: 404) == false)
        #expect(RetryPolicy.isRetriable(statusCode: 401) == false) // handled separately
    }

    @Test func maxRetriesIsCapped() {
        #expect(RetryPolicy.maxRetries == 3)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test 2>&1 | grep -E '(Test.*PASS|Test.*FAIL|error:.*RetryPolicy)'`
Expected: FAIL — `RetryPolicy` not defined.

- [ ] **Step 3: Implement RetryPolicy**

Add to the bottom of `Serif/Services/Gmail/GmailAPIClient.swift`, before the closing of the file:

```swift
// MARK: - Retry Policy

enum RetryPolicy {
    static let maxRetries = 3

    /// Returns true for status codes that should trigger a retry.
    static func isRetriable(statusCode: Int) -> Bool {
        switch statusCode {
        case 429, 500, 503: return true
        default: return false
        }
    }

    /// Exponential backoff delay: 2^attempt seconds + random jitter (0–0.5× base).
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let base = pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...(base * 0.5))
        return base + jitter
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test 2>&1 | grep -E '(RetryDelay.*passed|RetryDelay.*failed)'`
Expected: All 4 tests PASS.

- [ ] **Step 5: Wire retry logic into `perform()` method**

In `GmailAPIClient.swift`, replace the `perform()` method with retry support. The key change: wrap the URLSession call in a retry loop. On retriable status codes, sleep with backoff and retry. On 401, throw `.unauthorized` (the caller — `rawRequest()` — handles refresh since it runs on `@MainActor`).

Replace the `perform()` method body (lines ~287–327) with:

```swift
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
                // Intentionally swallow CancellationError during backoff sleep —
                // if the task is cancelled, the next loop iteration's URLSession call
                // will throw, which we convert to .networkError.
                try? await Task.sleep(for: .seconds(RetryPolicy.delay(forAttempt: attempt)))
                continue
            }
            throw .httpError(http.statusCode, data)
        }
    }
    // Should not reach here, but satisfy the compiler
    throw .httpError(0, Data())
}
```

- [ ] **Step 6: Add 401 auto-retry in `rawRequest()`**

`rawRequest()` runs on `@MainActor` (it's not `@concurrent`), so it can safely access `refreshTasks` and call `refreshAndRetry()`. When `perform()` throws `.unauthorized`, catch it, refresh the token, and retry once.

**First**, add a helper method to `GmailAPIClient` (inside the class, after `validToken`):

```swift
/// Forces a token refresh (invalidates cached token). Used for 401 auto-retry.
/// Runs on @MainActor since it mutates refreshTasks.
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
```

**Then**, replace the entire body of `rawRequest()` (lines ~32–85) with this unified implementation that handles 401 retry in both DEBUG and release:

```swift
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

    // Closure that runs the actual perform() call
    let doPerform = { (accessToken: String) async throws(GmailAPIError) -> Data in
        #if DEBUG
        let reqHeaders: [String: String] = {
            var h = ["Authorization": "Bearer [hidden]"]
            if let ct = contentType { h["Content-Type"] = ct }
            return h
        }()
        let reqBody: String? = body.flatMap { String(data: $0, encoding: .utf8) }
        let t0 = Date()
        do {
            let (data, code, respHeaders) = try await self.perform(path: path, method: method, body: body, contentType: contentType, fields: fields, accessToken: accessToken)
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
        let (data, _, _) = try await self.perform(path: path, method: method, body: body, contentType: contentType, fields: fields, accessToken: accessToken)
        return data
        #endif
    }

    // First attempt
    do {
        return try await doPerform(token.accessToken)
    } catch .unauthorized {
        // 401 auto-retry: refresh token and try once more
        let fresh = try await refreshAndRetry(accountID: accountID)
        return try await doPerform(fresh.accessToken)
    }
}
```

Note: This replaces the existing `rawRequest` entirely. The 401 retry logic is now shared between DEBUG and release builds via the `doPerform` closure.

- [ ] **Step 7: Run full test suite**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: All tests PASS.

- [ ] **Step 8: Commit**

```bash
git add Serif/Services/Gmail/GmailAPIClient.swift SerifTests/GmailAPIClientRetryTests.swift
git commit -m "feat: add exponential backoff retry and 401 auto-retry to GmailAPIClient"
```

---

### Task 2: Deduplicate `requestURL()` Debug Logging (DRY)

**Files:**
- Modify: `Serif/Services/Gmail/GmailAPIClient.swift`

After Task 1, `rawRequest()` already has clean debug logging in its `doPerform` closure. The remaining DRY target is `requestURL()`, which has its own ~25-line `#if DEBUG` block. Since `requestURL()` uses `URLSession` directly (not `perform()`), we simplify it by extracting the logging into its `doPerform` closure pattern — mirroring `rawRequest()`.

- [ ] **Step 1: Refactor `requestURL()` to use doPerform pattern with 401 auto-retry**

Replace the entire `requestURL()` method with:

```swift
func requestURL<T: Decodable>(_ urlString: String, accountID: String) async throws(GmailAPIError) -> T {
    guard NetworkMonitor.shared.isConnected else { throw .offline }
    let token = try await validToken(for: accountID)
    guard let url = URL(string: urlString) else { throw .invalidURL }

    let path = url.path + (url.query.map { "?\($0)" } ?? "")

    let doRequest = { (accessToken: String) async throws(GmailAPIError) -> T in
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        #if DEBUG
        let t0 = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw GmailAPIError.invalidURL }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            APILogger.shared.log(APILogEntry(
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
            APILogger.shared.log(APILogEntry(
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

    // First attempt + 401 auto-retry
    do {
        return try await doRequest(token.accessToken)
    } catch .unauthorized {
        let fresh = try await refreshAndRetry(accountID: accountID)
        return try await doRequest(fresh.accessToken)
    }
}
```

This adds 401 auto-retry to `requestURL()` (which was previously missing) and keeps the method self-contained.

- [ ] **Step 2: Run full test suite**

Run: `xcodebuild -scheme Serif -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: All tests PASS.

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/Gmail/GmailAPIClient.swift
git commit -m "refactor: add 401 auto-retry to requestURL and deduplicate logging (DRY)"
```

---

### Task 3: Fix URL-Encoding Gaps

**Files:**
- Modify: `Serif/Services/Gmail/GmailMessageService.swift`
- Modify: `Serif/Services/Gmail/GmailProfileService.swift`
- Create: `SerifTests/URLEncodingTests.swift`

- [ ] **Step 1: Write failing tests for URL path building helpers**

Create `SerifTests/URLEncodingTests.swift`:

```swift
import Testing
import Foundation
@testable import Serif

@Suite struct URLEncodingTests {

    @Test func buildLabelQueryEncodesSpecialChars() {
        // '+' in a label ID must be percent-encoded in the query string
        let path = GmailPathBuilder.labelQueryParam("Label+Test")
        #expect(path == "&labelIds=Label%2BTest")
    }

    @Test func buildLabelQueryPassesThroughStandardLabels() {
        let path = GmailPathBuilder.labelQueryParam("INBOX")
        #expect(path == "&labelIds=INBOX")
    }

    @Test func buildSendAsPathEncodesPlus() {
        let path = GmailPathBuilder.sendAsPath("user+alias@example.com")
        #expect(path.contains("%2B"))
        #expect(!path.contains("+"))
        #expect(path.hasPrefix("/users/me/settings/sendAs/"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `GmailPathBuilder` not defined.

- [ ] **Step 3: Create `GmailPathBuilder` and implement helpers**

Add to `Serif/Services/Gmail/GmailAPIClient.swift` (after the `RetryPolicy` enum):

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: All 3 `URLEncodingTests` PASS.

- [ ] **Step 5: Use `GmailPathBuilder` in `listMessages`**

In `GmailMessageService.swift`, change:
```swift
for label in labelIDs { path += "&labelIds=\(label)" }
```
To:
```swift
for label in labelIDs { path += GmailPathBuilder.labelQueryParam(label) }
```

- [ ] **Step 6: Use `GmailPathBuilder` in `updateSignature`**

In `GmailProfileService.swift`, change:
```swift
path: "/users/me/settings/sendAs/\(sendAsEmail)",
```
To:
```swift
path: GmailPathBuilder.sendAsPath(sendAsEmail),
```

- [ ] **Step 7: Run full test suite**

Expected: All tests PASS.

- [ ] **Step 8: Commit**

```bash
git add Serif/Services/Gmail/GmailAPIClient.swift Serif/Services/Gmail/GmailMessageService.swift Serif/Services/Gmail/GmailProfileService.swift SerifTests/URLEncodingTests.swift
git commit -m "fix: URL-encode label IDs and sendAs email via GmailPathBuilder"
```

---

### Task 4: Add Missing `fields` Parameters

**Files:**
- Modify: `Serif/Services/Gmail/GmailDraftService.swift`
- Modify: `Serif/Services/Gmail/GmailFilterService.swift`
- Modify: `Serif/Services/Gmail/GmailProfileService.swift`

Per Gmail API best practices, always use the `fields` parameter for partial responses.

- [ ] **Step 1: Add `fields` to `listDrafts`**

In `GmailDraftService.swift`, change `listDrafts`:
```swift
return try await client.request(path: path, accountID: accountID)
```
To:
```swift
return try await client.request(
    path: path,
    fields: "drafts(id,message(id,threadId)),nextPageToken,resultSizeEstimate",
    accountID: accountID
)
```

- [ ] **Step 2: Add `fields` to `getDraft`**

In `GmailDraftService.swift`, change `getDraft`:
```swift
try await client.request(
    path: "/users/me/drafts/\(id)?format=\(format)",
    accountID: accountID
)
```
To:
```swift
let draftFields: String? = switch format {
case "metadata": "id,message(id,threadId,labelIds,snippet,payload/headers,internalDate)"
case "full": "id,message(id,threadId,labelIds,snippet,payload,internalDate)"
default: nil
}
return try await client.request(
    path: "/users/me/drafts/\(id)?format=\(format)",
    fields: draftFields,
    accountID: accountID
)
```

- [ ] **Step 3: Add `fields` to `listFilters`**

In `GmailFilterService.swift`, change `listFilters`:
```swift
let response: GmailFilterListResponse = try await client.request(path: "/users/me/settings/filters", accountID: accountID)
```
To:
```swift
let response: GmailFilterListResponse = try await client.request(
    path: "/users/me/settings/filters",
    fields: "filter(id,criteria,action)",
    accountID: accountID
)
```

- [ ] **Step 4: Add `fields` to `listSendAs`**

In `GmailProfileService.swift`, change `listSendAs`:
```swift
let response: GmailSendAsListResponse = try await GmailAPIClient.shared.request(
    path: "/users/me/settings/sendAs",
    accountID: accountID
)
```
To:
```swift
let response: GmailSendAsListResponse = try await GmailAPIClient.shared.request(
    path: "/users/me/settings/sendAs",
    fields: "sendAs(sendAsEmail,displayName,signature,isDefault,isPrimary)",
    accountID: accountID
)
```

- [ ] **Step 5: Run full test suite**

Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Serif/Services/Gmail/GmailDraftService.swift Serif/Services/Gmail/GmailFilterService.swift Serif/Services/Gmail/GmailProfileService.swift
git commit -m "perf: add fields parameter to draft, filter, and sendAs API calls"
```

---

## Chunk 2: SOLID & DRY Structural Improvements

### Task 5: Extract PeopleAPIService from GmailProfileService (SRP)

**Files:**
- Create: `Serif/Services/PeopleAPIService.swift`
- Modify: `Serif/Services/Gmail/GmailProfileService.swift`

`GmailProfileService` currently handles Gmail profile, OAuth2 userinfo, SendAs aliases, AND People API contacts. The contacts concern belongs in its own service.

- [ ] **Step 1: Create `PeopleAPIService.swift`**

Move the contacts-related code out of `GmailProfileService` into a new file:

```swift
import Foundation

/// Fetches contacts and photos from the Google People API.
@MainActor
final class PeopleAPIService {
    static let shared = PeopleAPIService()
    private init() {}

    /// Loads contacts: uses local cache if available, otherwise fetches from network.
    func loadContactPhotos(accountID: String) async {
        let local = ContactStore.shared.contacts(for: accountID)
        if !local.isEmpty {
            print("[Serif] Using \(local.count) cached contacts for \(accountID)")
            for contact in local {
                if let url = contact.photoURL {
                    ContactPhotoCache.shared.set(url, for: contact.email)
                }
            }
            return
        }
        await fetchAndStoreContacts(accountID: accountID)
    }

    /// Forces a network refresh of contacts, replacing the local cache.
    func refreshContacts(accountID: String) async {
        await fetchAndStoreContacts(accountID: accountID)
    }

    /// Fetches contacts from People API and persists them.
    private func fetchAndStoreContacts(accountID: String) async {
        var allContacts: [StoredContact] = []

        // 1. Fetch "My Contacts" via connections
        do {
            var pageToken: String? = nil
            repeat {
                var urlStr = "https://people.googleapis.com/v1/people/me/connections"
                    + "?personFields=names,emailAddresses,photos&pageSize=1000&sortOrder=LAST_MODIFIED_DESCENDING"
                if let pt = pageToken { urlStr += "&pageToken=\(pt)" }
                let response: PeopleConnectionsResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)
                for person in response.connections ?? [] {
                    let displayName = person.names?.first?.displayName ?? ""
                    let photoURL = person.photos?.first(where: { $0.default != true })?.url
                    for addr in person.emailAddresses ?? [] {
                        guard let email = addr.value, !email.isEmpty else { continue }
                        if let url = photoURL {
                            ContactPhotoCache.shared.set(url, for: email)
                        }
                        allContacts.append(StoredContact(name: displayName, email: email.lowercased(), photoURL: photoURL))
                    }
                }
                pageToken = response.nextPageToken
            } while pageToken != nil
            print("[Serif] Loaded \(allContacts.count) contacts from Connections")
        } catch {
            print("[Serif] Connections fetch error: \(error)")
        }

        // 2. Fetch "Other Contacts" (auto-created from email interactions)
        do {
            var pageToken: String? = nil
            repeat {
                var urlStr = "https://people.googleapis.com/v1/otherContacts"
                    + "?readMask=names,emailAddresses&pageSize=1000"
                if let pt = pageToken { urlStr += "&pageToken=\(pt)" }
                let response: OtherContactsResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)
                let beforeCount = allContacts.count
                for person in response.otherContacts ?? [] {
                    let displayName = person.names?.first?.displayName ?? ""
                    for addr in person.emailAddresses ?? [] {
                        guard let email = addr.value, !email.isEmpty else { continue }
                        allContacts.append(StoredContact(name: displayName, email: email.lowercased()))
                    }
                }
                print("[Serif] Loaded \(allContacts.count - beforeCount) from Other Contacts page")
                pageToken = response.nextPageToken
            } while pageToken != nil
        } catch {
            print("[Serif] Other Contacts fetch error: \(error)")
        }

        // Deduplicate by email and persist
        var seen = Set<String>()
        let unique = allContacts.filter { seen.insert($0.email).inserted }
        ContactStore.shared.setContacts(unique, for: accountID)
        print("[Serif] Total unique contacts stored: \(unique.count)")
    }
}

// MARK: - People API response models

struct PeopleConnectionsResponse: Decodable {
    let connections: [PersonResource]?
    let nextPageToken: String?
}

struct OtherContactsResponse: Decodable {
    let otherContacts: [PersonResource]?
    let nextPageToken: String?
}

struct PersonResource: Decodable {
    let emailAddresses: [PersonEmail]?
    let photos: [PersonPhoto]?
    let names: [PersonName]?
}

struct PersonEmail: Decodable {
    let value: String?
}

struct PersonPhoto: Decodable {
    let url: String?
    let `default`: Bool?
}

struct PersonName: Decodable {
    let displayName: String?
}
```

- [ ] **Step 2: Remove contacts code from `GmailProfileService`**

Remove from `GmailProfileService.swift`:
- The `loadContactPhotos` method
- The `refreshContacts` method
- The `fetchAndStoreContacts` method
- The private People API response model structs (`PeopleConnectionsResponse`, `OtherContactsResponse`, `PersonResource`, `PersonEmail`, `PersonPhoto`, `PersonName`)

Keep in `GmailProfileService.swift`:
- `getProfile`
- `getUserInfo`
- `listSendAs`
- `updateSignature`
- `getSignature`

Also keep `StoredContact`, `ContactStore`, `ContactPhotoCache`, and `GoogleUserInfo` in `GmailProfileService.swift` — they are used by both services.

- [ ] **Step 3: Update all callers**

Search for `GmailProfileService.shared.loadContactPhotos` and `GmailProfileService.shared.refreshContacts` across the codebase and replace with `PeopleAPIService.shared.loadContactPhotos` and `PeopleAPIService.shared.refreshContacts`.

Run: `grep -rn "loadContactPhotos\|refreshContacts" Serif/` to find all call sites.

- [ ] **Step 4: Run full test suite**

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Serif/Services/PeopleAPIService.swift Serif/Services/Gmail/GmailProfileService.swift Serif/
git commit -m "refactor: extract PeopleAPIService from GmailProfileService (SRP)"
```

---

### Task 6: Switch Draft Batch Fetch to Use Batch API (DRY)

**Files:**
- Modify: `Serif/Services/Gmail/GmailDraftService.swift`

`GmailDraftService.getDrafts` currently uses `TaskGroup` with individual HTTP calls (5 at a time). `GmailMessageService.getMessages` already properly uses the batch API. Align them.

- [ ] **Step 1: Replace `getDrafts` implementation**

Replace the existing `getDrafts` method in `GmailDraftService.swift`:

```swift
/// Fetches a batch of drafts using Gmail's batch API (up to 50 per request).
@concurrent func getDrafts(ids: [String], accountID: String, format: String = "metadata") async throws -> [GmailDraft] {
    guard !ids.isEmpty else { return [] }

    let batchSize = 50
    var all: [GmailDraft] = []
    let decoder = JSONDecoder()

    for offset in stride(from: 0, to: ids.count, by: batchSize) {
        let batch = Array(ids[offset..<min(offset + batchSize, ids.count)])
        let requests = batch.map { id in
            (id: id, method: "GET", path: "/gmail/v1/users/me/drafts/\(id)?format=\(format)", body: nil as Data?)
        }

        let results = try await GmailAPIClient.shared.batchRequest(requests: requests, accountID: accountID)

        for result in results {
            guard (200...299).contains(result.statusCode) else {
                #if DEBUG
                print("[GmailAPI] Batch draft \(result.id) failed: HTTP \(result.statusCode)")
                #endif
                continue
            }
            do {
                let draft = try decoder.decode(GmailDraft.self, from: result.data)
                all.append(draft)
            } catch {
                #if DEBUG
                print("[GmailAPI] Batch draft decode failed for \(result.id): \(error)")
                #endif
            }
        }
    }

    return all.sorted {
        ($0.message?.date ?? .distantPast) > ($1.message?.date ?? .distantPast)
    }
}
```

- [ ] **Step 2: Run full test suite**

Expected: All tests PASS. Also verify `DraftLifecycleTests` still pass.

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/Gmail/GmailDraftService.swift
git commit -m "refactor: switch draft batch fetch to use Gmail batch API (DRY)"
```

---

## Summary

| Task | Type | Impact |
|------|------|--------|
| 1. Retry + exponential backoff | Reliability | Critical — required by Gmail API docs |
| 2. Extract debug logging | DRY | Medium — removes ~50 lines of duplication |
| 3. URL encoding fixes | Bug fix | Low–Medium — prevents edge-case failures |
| 4. `fields` parameters | Performance | Medium — reduces data transfer |
| 5. Extract PeopleAPIService | SOLID (SRP) | Medium — clean separation of concerns |
| 6. Draft batch API | DRY | Medium — consistent batch pattern |
