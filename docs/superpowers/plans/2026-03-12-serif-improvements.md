# Serif Improvements Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform Serif into a state-of-the-art native macOS Gmail client with batch API performance, snooze/scheduled send, Apple Intelligence features, and full macOS 26 platform integration.

**Architecture:** MVVM with coordinator navigation. New features follow existing patterns: Services as `@MainActor final class` singletons, ViewModels as `@Observable @MainActor final class`, Views as pure SwiftUI structs. Persistence via JSON files keyed by accountID at `~/Library/Application Support/com.genyus.serif.app/mail-cache/{accountID}/`.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 26 SDK, Gmail REST API v1, Apple Foundation Models framework, App Intents, AppAuth (OAuth)

---

## File Structure

### New Files (25)

| File | Responsibility |
|------|---------------|
| `Serif/Services/Gmail/GmailFilterService.swift` | Gmail Filters API CRUD wrapper |
| `Serif/Services/SnoozeStore.swift` | Snooze persistence + CRUD per account |
| `Serif/Services/SnoozeMonitor.swift` | Background timer (60s) + launch-time check for expired snoozes |
| `Serif/Services/ScheduledSendStore.swift` | Scheduled send persistence per account |
| `Serif/Services/ScheduledSendMonitor.swift` | Background timer for scheduled sends (unified with SnoozeMonitor) |
| `Serif/Services/OfflineActionQueue.swift` | Queue mutations when offline, replay on reconnect |
| `Serif/Services/SmartReplyProvider.swift` | Foundation Models `@Generable` smart reply generation + cache |
| `Serif/Services/EmailClassifier.swift` | Foundation Models email tagging (needsReply, fyiOnly, etc.) |
| `Serif/Services/NotificationService.swift` | Local notification categories, generation, action handling |
| `Serif/Models/OfflineAction.swift` | Offline action model (ActionType enum + params) |
| `Serif/Models/Command.swift` | Command palette command model |
| `Serif/Models/EmailTags.swift` | `@Generable` classification tags |
| `Serif/Models/EmailDragItem.swift` | Transferable drag payload for email rows |
| `Serif/Views/Common/CommandPaletteView.swift` | Floating command palette overlay |
| `Serif/Views/Common/SnoozePickerView.swift` | Snooze/schedule time preset popover |
| `Serif/Views/Compose/ScheduleSendButton.swift` | Split send button with schedule dropdown |
| `Serif/Views/EmailDetail/SmartReplyChipsView.swift` | Tappable smart reply suggestion chips |
| `Serif/Views/EmailList/CategoryTabBar.swift` | Horizontal inbox category tabs with badges |
| `Serif/Views/Settings/FiltersSettingsView.swift` | Gmail filter list in settings |
| `Serif/Views/Settings/FilterEditorView.swift` | Create/edit filter form |
| `Serif/ViewModels/CommandPaletteViewModel.swift` | Command indexing + fuzzy search |
| `Serif/Intents/EmailEntity.swift` | IndexedEntity for Spotlight |
| `Serif/Intents/OpenEmailIntent.swift` | App Intent: open email |
| `Serif/Intents/ComposeEmailIntent.swift` | App Intent: compose email |
| `Serif/Intents/SearchEmailIntent.swift` | App Intent: search inbox |

### Modified Files (27)

| File | Changes |
|------|---------|
| `Serif/Services/Gmail/GmailAPIClient.swift` | Add `batchRequest()`, `fields` parameter, batch endpoint constant, User-Agent header |
| `Serif/Services/Gmail/GmailMessageService.swift` | Refactor `getMessages()` to use batch API, add `fields` to calls |
| `Serif/Services/Auth/OAuthService.swift` | Verify/enable PKCE S256 configuration |
| `Serif/Services/SummaryService.swift` | Add `@Generable EmailInsight`, chain summarization, streaming |
| `Serif/Services/LabelSuggestionService.swift` | Verify Foundation Models usage, add dismissal learning |
| `Serif/Services/MessageFetchService.swift` | Call EmailClassifier in `analyzeInBackground()` |
| `Serif/Services/MailCacheStore.swift` | Store/load EmailTags alongside message cache |
| `Serif/Services/HistorySyncService.swift` | Trigger NotificationService on new messages |
| `Serif/Services/SpotlightIndexer.swift` | Migrate from CSSearchableItem to IndexedEntity |
| `Serif/Models/Email.swift` | Add `.snoozed`, `.scheduled` to Folder enum |
| `Serif/ContentView.swift` | Command palette overlay, background extension, Handoff |
| `Serif/SerifApp.swift` | Register notification categories, set delegate |
| `Serif/Views/Common/SerifCommands.swift` | Register Cmd+K shortcut |
| `Serif/Views/EmailList/ListPaneView.swift` | Category tab bar, offline banner, scroll edge effects |
| `Serif/Views/EmailList/EmailRowView.swift` | Nudge text, tag badges, accessibility, draggable |
| `Serif/Views/EmailList/EmailListView.swift` | Rotors, drag container, default focus |
| `Serif/Views/EmailList/EmailContextMenu.swift` | Snooze menu item, "Create filter" option |
| `Serif/Views/EmailDetail/DetailToolbarView.swift` | Snooze button, toolbar grouping |
| `Serif/Views/EmailDetail/ReplyBarView.swift` | Smart reply chips above reply area |
| `Serif/Views/EmailDetail/EmailDetailView.swift` | Insight card, detail accessibility |
| `Serif/Views/EmailDetail/LabelEditorView.swift` | Dismiss tracking for label suggestions |
| `Serif/Views/EmailDetail/AttachmentChipView.swift` | Draggable with file data |
| `Serif/Views/EmailDetail/EmailHoverSummaryView.swift` | Show structured EmailInsight |
| `Serif/Views/Compose/ComposeView.swift` | Undo-send countdown UI, schedule send button |
| `Serif/ViewModels/ComposeViewModel.swift` | `scheduleSend(at:)`, route send through UndoActionManager |
| `Serif/ViewModels/EmailActionCoordinator.swift` | Route through OfflineActionQueue when offline |
| `Serif/ViewModels/EmailDetailViewModel.swift` | Smart reply trigger, NSUserActivity for Handoff |
| `Serif/Views/Sidebar/SidebarView.swift` | Snoozed/Scheduled folders, drop destinations, remove custom backgrounds |
| `Serif/Views/Settings/SettingsView.swift` | Filters tab, notification toggle |

---

## Chunk 1: Phase 1 — "Instant Inbox" (Performance + Gmail Categories)

### Task 1: Batch API — Add `batchRequest()` to GmailAPIClient

**Files:**
- Modify: `Serif/Services/Gmail/GmailAPIClient.swift`

- [ ] **Step 1: Add batch endpoint constant and `batchRequest()` method**

Add after line 10 (`private let baseURL = ...`):

```swift
private let batchURL = "https://www.googleapis.com/batch/gmail/v1"
```

Add before the `// MARK: - Token refresh` section (line 132):

```swift
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

    return parseBatchResponse(data: data, boundary: responseBoundary)
}

@concurrent private func parseBatchResponse(data: Data, boundary: String) throws(GmailAPIError) -> [(id: String, statusCode: Int, data: Data)] {
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
```

- [ ] **Step 2: Build and verify compilation**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/Gmail/GmailAPIClient.swift
git commit -m "feat: add batch API support to GmailAPIClient"
```

---

### Task 2: Batch API — Refactor `getMessages()` to Use Batch

**Files:**
- Modify: `Serif/Services/Gmail/GmailMessageService.swift:42-60`

- [ ] **Step 1: Replace `getMessages()` with batch implementation**

Replace lines 41-60 (the doc comment `/// Fetches a batch of message IDs...` through the end of the method) with:

```swift
/// Fetches a batch of messages using Gmail's batch API (up to 50 per request).
@concurrent func getMessages(ids: [String], accountID: String, format: String = "metadata") async throws -> [GmailMessage] {
    guard !ids.isEmpty else { return [] }

    let batchSize = 50
    var all: [GmailMessage] = []
    let decoder = JSONDecoder()

    for offset in stride(from: 0, to: ids.count, by: batchSize) {
        let batch = Array(ids[offset..<min(offset + batchSize, ids.count)])
        let requests = batch.map { id in
            (id: id, method: "GET", path: "/gmail/v1/users/me/messages/\(id)?format=\(format)", body: nil as Data?)
        }

        let results = try await GmailAPIClient.shared.batchRequest(requests: requests, accountID: accountID)

        for result in results {
            guard (200...299).contains(result.statusCode) else {
                #if DEBUG
                print("[GmailAPI] Batch part \(result.id) failed: HTTP \(result.statusCode)")
                #endif
                continue
            }
            do {
                let msg = try decoder.decode(GmailMessage.self, from: result.data)
                all.append(msg)
            } catch {
                #if DEBUG
                print("[GmailAPI] Batch decode failed for \(result.id): \(error)")
                #endif
            }
        }
    }

    return all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
}
```

- [ ] **Step 2: Build and verify compilation**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/Gmail/GmailMessageService.swift
git commit -m "perf: use Gmail batch API for message fetching (50 per request)"
```

---

### Task 3: Add `fields` Parameter to API Client

**Files:**
- Modify: `Serif/Services/Gmail/GmailAPIClient.swift` — the `request<T>`, `rawRequest`, and `perform` methods

**Note:** Line numbers reference the file state *before* Task 1 edits. After Task 1, all line numbers below the insertion point shift. Use symbol names (method signatures) to locate edit targets.

- [ ] **Step 1: Add `fields` parameter to `request()`, `rawRequest()`, and `perform()`**

Find the `func request<T: Decodable>` method and add `fields: String? = nil` parameter after `contentType`:

```swift
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
```

Find the `func rawRequest` method and add the same `fields: String? = nil` parameter. Pass `fields` through to every `perform()` call inside both the `#if DEBUG` and `#else` branches. For example, change:

```swift
// Before:
let (data, code, respHeaders) = try await perform(path: path, method: method, body: body, contentType: contentType, accessToken: token.accessToken)
// After:
let (data, code, respHeaders) = try await perform(path: path, method: method, body: body, contentType: contentType, fields: fields, accessToken: token.accessToken)
```

Apply the same change to the `#else` branch's `perform()` call.

Find the `private func perform` method and add `fields: String?` parameter. Prepend the fields query to the path:

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
    case 200...299: return (data, http.statusCode, headers)
    case 401:       throw .unauthorized
    default:        throw .httpError(http.statusCode, data)
    }
}
```

- [ ] **Step 2: Build and verify compilation**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/Gmail/GmailAPIClient.swift
git commit -m "perf: add fields parameter for partial API responses"
```

---

### Task 4: Apply `fields` to Message Service Calls

**Files:**
- Modify: `Serif/Services/Gmail/GmailMessageService.swift`

- [ ] **Step 1: Add `fields` to `listMessages()` and `getMessage()`**

Find the `listMessages()` method — update its `client.request` call to pass `fields`:

```swift
return try await client.request(
    path: path,
    fields: "messages(id,threadId),nextPageToken,resultSizeEstimate",
    accountID: accountID
)
```

Find the `getMessage()` method — add conditional fields based on format:

```swift
@concurrent func getMessage(id: String, accountID: String, format: String = "full") async throws(GmailAPIError) -> GmailMessage {
    let messageFields: String? = switch format {
    case "metadata": "id,threadId,labelIds,snippet,payload/headers,internalDate,sizeEstimate"
    case "full": "id,threadId,labelIds,snippet,payload,internalDate"
    default: nil
    }
    return try await client.request(
        path: "/users/me/messages/\(id)?format=\(format)",
        fields: messageFields,
        accountID: accountID
    )
}
```

Find the `getThread()` method — add fields:

```swift
@concurrent func getThread(id: String, accountID: String) async throws(GmailAPIError) -> GmailThread {
    try await client.request(
        path: "/users/me/threads/\(id)?format=full",
        fields: "id,messages(id,threadId,labelIds,snippet,payload,internalDate)",
        accountID: accountID
    )
}
```

Find the `listHistory()` method — add fields:

```swift
return try await client.request(
    path: path,
    fields: "history(id,messages(id,labelIds),messagesAdded,messagesDeleted,labelsAdded,labelsRemoved),historyId,nextPageToken",
    accountID: accountID
)
```

Note: Also update `GmailLabelService` to pass `fields` on `labels.list` calls:
```swift
fields: "labels(id,name,type,messagesTotal,messagesUnread,threadsTotal,threadsUnread,color,labelListVisibility,messageListVisibility)"
```

- [ ] **Step 2: Build and verify compilation**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/Gmail/GmailMessageService.swift
git commit -m "perf: apply fields parameter to reduce API payload sizes"
```

---

### Task 5: Verify Compression + Debug Logging

**Files:**
- Modify: `Serif/Services/Gmail/GmailAPIClient.swift` — `rawRequest` method

Note: The `User-Agent` header was already added in Task 3's `perform()` rewrite. This task only adds compression verification logging.

- [ ] **Step 1: Add debug compression logging**

In the `rawRequest()` method, inside the `#if DEBUG` success path (after the `APILogger.shared.log(...)` call in the success `do` block), add:

```swift
if let encoding = respHeaders["Content-Encoding"] {
    print("[GmailAPI] Compression: \(encoding) for \(path)")
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/Gmail/GmailAPIClient.swift
git commit -m "chore: add User-Agent header and verify compression is active"
```

---

### Task 6: Verify/Enable PKCE for OAuth

**Files:**
- Modify: `Serif/Services/Auth/OAuthService.swift:32-40`

- [ ] **Step 1: Verify AppAuth PKCE and add explicit S256 configuration**

AppAuth-iOS supports PKCE natively via `OIDAuthorizationRequest`. The current code at line 32 uses the basic initializer which does NOT explicitly enable PKCE. Update the authorization request to use the full initializer with PKCE:

```swift
guard let codeVerifier = OIDAuthorizationRequest.generateCodeVerifier() else {
    throw OAuthError.listenerFailed
}
let codeChallenge = OIDAuthorizationRequest.codeChallengeS256(forVerifier: codeVerifier)

let request = OIDAuthorizationRequest(
    configuration: config,
    clientId: GoogleCredentials.clientID,
    clientSecret: GoogleCredentials.clientSecret,
    scopes: GoogleCredentials.scopes,
    redirectURL: redirectURI,
    responseType: OIDResponseTypeCode,
    additionalParameters: ["access_type": "offline", "prompt": "consent"],
    codeVerifier: codeVerifier,
    codeChallenge: codeChallenge,
    codeChallengeMethod: OIDOAuthorizationRequestCodeChallengeMethodS256
)
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/Auth/OAuthService.swift
git commit -m "security: enable PKCE S256 for OAuth authorization"
```

---

### Task 7: Gmail Categories — CategoryTabBar View

**Files:**
- Create: `Serif/Views/EmailList/CategoryTabBar.swift`

- [ ] **Step 1: Create the category tab bar view**

```swift
import SwiftUI

struct CategoryTabBar: View {
    @Binding var selectedCategory: InboxCategory
    @Binding var priorityFilterOn: Bool
    let unreadCounts: [InboxCategory: Int]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InboxCategory.allCases) { category in
                categoryTab(category)
            }

            Spacer()

            // Priority filter toggle (Gmail IMPORTANT label)
            Button {
                priorityFilterOn.toggle()
            } label: {
                Label("Priority", systemImage: priorityFilterOn ? "flag.fill" : "flag")
                    .font(.caption)
                    .foregroundStyle(priorityFilterOn ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Show only important emails")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func categoryTab(_ category: InboxCategory) -> some View {
        Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 4) {
                Text(category.displayName)
                    .font(.subheadline)
                    .fontWeight(selectedCategory == category ? .semibold : .regular)

                if let count = unreadCounts[category], count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(selectedCategory == category ? Color.accentColor : .secondary.opacity(0.2))
                        .foregroundStyle(selectedCategory == category ? .white : .secondary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selectedCategory == category ? Color.accentColor.opacity(0.1) : .clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedCategory == category ? Color.accentColor : .secondary)
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/EmailList/CategoryTabBar.swift
git commit -m "feat: add CategoryTabBar view for inbox category filtering"
```

---

### Task 8: Gmail Categories — Integrate Tab Bar into ListPaneView

**Files:**
- Modify: `Serif/Views/EmailList/ListPaneView.swift`

- [ ] **Step 1: Add category state and tab bar to ListPaneView**

Add a `selectedCategory` binding and the tab bar above the email list. Update the body at line 28:

```swift
@State private var selectedCategory: InboxCategory = .all

var body: some View {
    VStack(spacing: 0) {
        if selectedFolder == .inbox {
            CategoryTabBar(
                selectedCategory: $selectedCategory,
                unreadCounts: mailboxViewModel.categoryUnreadCounts
            )
            Divider()
        }
        emailList
    }
    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
    .onChange(of: selectedCategory) { _, newCategory in
        Task { await mailboxViewModel.switchCategory(newCategory) }
    }
}
```

Note: `categoryUnreadCounts` already exists on `MailboxViewModel`. If `switchCategory()` does not exist, add it to `MailboxViewModel`:

```swift
func switchCategory(_ category: InboxCategory) async {
    currentCategory = category
    await loadMessages(labelIDs: category.gmailLabelIDs)
}
```

The implementing engineer should check `MailboxViewModel` for existing category handling and integrate accordingly. The category filtering logic already exists via `InboxCategory.gmailLabelIDs`.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/EmailList/ListPaneView.swift
git commit -m "feat: integrate category tab bar into inbox list pane"
```

---

## Chunk 2: Phase 2 — "Time Control" (Snooze + Scheduled Send + Command Palette + Offline Queue + Nudging)

### Task 9: Snooze — Add `.snoozed` and `.scheduled` to Folder Enum

**Files:**
- Modify: `Serif/Models/Email.swift:251-304`

- [ ] **Step 1: Add new cases to Folder enum**

Add after `.trash` (line 261):

```swift
case snoozed = "Snoozed"
case scheduled = "Scheduled"
```

Add icon cases in the `icon` computed property (after `.trash` case):

```swift
case .snoozed:     return "clock.fill"
case .scheduled:   return "calendar.badge.clock"
```

Add gmailLabelID cases (return nil — these are client-side only):

```swift
case .snoozed, .scheduled: return nil
```

Add gmailQuery cases (return nil — handled by local stores):

```swift
case .snoozed, .scheduled: return nil
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Models/Email.swift
git commit -m "feat: add snoozed and scheduled cases to Folder enum"
```

---

### Task 10: Snooze — Create SnoozeStore

**Files:**
- Create: `Serif/Services/SnoozeStore.swift`

- [ ] **Step 1: Create the snooze persistence service**

```swift
import Foundation

struct SnoozedItem: Codable, Identifiable, Sendable {
    let id: UUID
    let messageId: String
    let threadId: String?
    let accountID: String
    let snoozeUntil: Date
    let originalLabelIds: [String]
    let subject: String
    let senderName: String

    init(
        id: UUID = UUID(),
        messageId: String,
        threadId: String? = nil,
        accountID: String,
        snoozeUntil: Date,
        originalLabelIds: [String] = [],
        subject: String = "",
        senderName: String = ""
    ) {
        self.id = id
        self.messageId = messageId
        self.threadId = threadId
        self.accountID = accountID
        self.snoozeUntil = snoozeUntil
        self.originalLabelIds = originalLabelIds
        self.subject = subject
        self.senderName = senderName
    }
}

private struct SnoozeFileContents: Codable {
    var version: Int = 1
    var items: [SnoozedItem] = []
}

@Observable
@MainActor
final class SnoozeStore {
    static let shared = SnoozeStore()
    private init() {}

    private(set) var items: [SnoozedItem] = []

    func load(accountID: String) {
        let url = fileURL(for: accountID)
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(SnoozeFileContents.self, from: data) else {
            items = []
            return
        }
        items = contents.items.filter { $0.accountID == accountID }
    }

    func add(_ item: SnoozedItem) {
        items.append(item)
        save(accountID: item.accountID)
    }

    func remove(messageId: String, accountID: String) {
        items.removeAll { $0.messageId == messageId && $0.accountID == accountID }
        save(accountID: accountID)
    }

    func expiredItems() -> [SnoozedItem] {
        let now = Date()
        return items.filter { $0.snoozeUntil <= now }
    }

    func itemsForAccount(_ accountID: String) -> [SnoozedItem] {
        items.filter { $0.accountID == accountID }
    }

    private func save(accountID: String) {
        let url = fileURL(for: accountID)
        let contents = SnoozeFileContents(version: 1, items: items.filter { $0.accountID == accountID })
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }

    private func fileURL(for accountID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.genyus.serif.app/mail-cache/\(accountID)/snoozed.json")
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/SnoozeStore.swift
git commit -m "feat: add SnoozeStore for persisting snoozed emails"
```

---

### Task 11: Snooze — Create SnoozeMonitor

**Files:**
- Create: `Serif/Services/SnoozeMonitor.swift`

- [ ] **Step 1: Create the background timer service**

```swift
import Foundation

@Observable
@MainActor
final class SnoozeMonitor {
    static let shared = SnoozeMonitor()
    private init() {}

    private var timerTask: Task<Void, Never>?

    func start() {
        guard timerTask == nil else { return }
        // Check immediately on start (covers app launch)
        Task { await checkExpired() }

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                guard !Task.isCancelled else { break }
                await self?.checkExpired()
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func checkExpired() async {
        let expired = SnoozeStore.shared.expiredItems()
        for item in expired {
            do {
                // Re-add INBOX label to unsnooze
                try await GmailMessageService.shared.modifyLabels(
                    id: item.messageId,
                    add: item.originalLabelIds.isEmpty ? [GmailSystemLabel.inbox] : item.originalLabelIds,
                    remove: [],
                    accountID: item.accountID
                )
                SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
            } catch {
                if case .httpError(404, _) = error as? GmailAPIError {
                    // Message deleted server-side — clean up
                    SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
                }
                // Other errors: retry next cycle
            }
        }
    }
}
```

Note: `modifyLabels` uses `accountID` parameter name — adjust to match existing API (`accountID` not `accountID`). The implementing engineer should verify parameter naming consistency.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/SnoozeMonitor.swift
git commit -m "feat: add SnoozeMonitor for background snooze expiry checks"
```

---

### Task 12: Snooze — Create SnoozePickerView

**Files:**
- Create: `Serif/Views/Common/SnoozePickerView.swift`

- [ ] **Step 1: Create the time picker popover**

```swift
import SwiftUI

struct SnoozePickerView: View {
    var title: String = "Snooze until..."
    let onSelect: (Date) -> Void
    @State private var showCustomPicker = false
    @State private var customDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            ForEach(presets, id: \.label) { preset in
                Button {
                    onSelect(preset.date)
                } label: {
                    HStack {
                        Label(preset.label, systemImage: preset.icon)
                        Spacer()
                        Text(preset.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }

            Divider()

            if showCustomPicker {
                DatePicker("Pick a date", selection: $customDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .padding(.horizontal, 8)

                Button("Confirm") {
                    onSelect(customDate)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            } else {
                Button {
                    showCustomPicker = true
                } label: {
                    Label("Pick Date & Time", systemImage: "calendar")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 260)
        .padding(.vertical, 4)
    }

    private var presets: [(label: String, icon: String, subtitle: String, date: Date)] {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)

        let laterToday: Date = {
            if hour < 15 {
                return calendar.date(byAdding: .hour, value: 3, to: now) ?? now
            } else {
                return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
            }
        }()

        let tomorrowMorning: Date = {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return now }
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }()

        let nextMonday: Date = {
            let weekday = calendar.component(.weekday, from: now)
            let daysUntilMonday = (9 - weekday) % 7
            let adjustedDays = daysUntilMonday == 0 ? 7 : daysUntilMonday
            guard let monday = calendar.date(byAdding: .day, value: adjustedDays, to: now) else { return now }
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: monday) ?? monday
        }()

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE, h:mm a"

        return [
            ("Later Today", "clock", formatter.string(from: laterToday), laterToday),
            ("Tomorrow Morning", "sunrise", "8:00 AM", tomorrowMorning),
            ("Next Week", "calendar", dayFormatter.string(from: nextMonday), nextMonday),
        ]
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/Common/SnoozePickerView.swift
git commit -m "feat: add SnoozePickerView with time presets and custom date picker"
```

---

### Task 13: Snooze — Add Snooze Button to DetailToolbarView

**Files:**
- Modify: `Serif/Views/EmailDetail/DetailToolbarView.swift`

- [ ] **Step 1: Add snooze callback and button**

Add a new callback property after line 22 (`var onPrint:...`):

```swift
var onSnooze: ((Date) -> Void)?
```

Add `@State private var showSnoozePicker = false` after line 29.

Add a snooze button in the toolbar after the archive/delete buttons (after line 88, before the `Divider`):

```swift
if let onSnooze {
    Button {
        showSnoozePicker = true
    } label: {
        Image(systemName: "clock")
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Snooze")
    .popover(isPresented: $showSnoozePicker) {
        SnoozePickerView { date in
            showSnoozePicker = false
            onSnooze(date)
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/EmailDetail/DetailToolbarView.swift
git commit -m "feat: add snooze button to detail toolbar"
```

---

### Task 14: Snooze — Add to EmailContextMenu and SidebarView

**Files:**
- Modify: `Serif/Views/EmailList/EmailContextMenu.swift`
- Modify: `Serif/Views/Sidebar/SidebarView.swift`

- [ ] **Step 1: Add snooze to context menu**

Add a new callback property to `EmailContextMenu` after line 15:

```swift
let onSnooze: ((Email, Date) -> Void)?
```

Add a snooze menu item after the star/unread section (after line 49):

```swift
Divider()
Menu {
    SnoozePickerView { date in
        onSnooze?(email, date)
    }
} label: {
    Label("Snooze", systemImage: "clock")
}
```

- [ ] **Step 2: Add snoozed folder to sidebar**

The `SidebarView` at line 91 iterates `Folder.allCases.filter { $0 != .labels }`. The new `.snoozed` and `.scheduled` cases will automatically appear since they're part of `CaseIterable`. Verify they render correctly with their icons.

If the order needs adjusting, update the filter to control placement — e.g., insert snoozed/scheduled after drafts.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Serif/Views/EmailList/EmailContextMenu.swift Serif/Views/Sidebar/SidebarView.swift
git commit -m "feat: add snooze to context menu and snoozed folder to sidebar"
```

---

### Task 15: Snooze — Wire Up Snooze Action in EmailActionCoordinator

**Files:**
- Modify: `Serif/ViewModels/EmailActionCoordinator.swift`

- [ ] **Step 1: Add snooze action method**

Add after `markNotSpamEmail` (line 131):

```swift
func snoozeEmail(_ email: Email, until date: Date, selectNext: (Email?) -> Void) {
    guard let msgID = email.gmailMessageID else { return }
    let vm = mailboxViewModel
    let removed = vm.removeOptimistically(msgID)
    selectNext(nil)

    let item = SnoozedItem(
        messageId: msgID,
        threadId: email.gmailThreadID,
        accountID: vm.accountID,
        snoozeUntil: date,
        originalLabelIds: email.gmailLabelIDs,
        subject: email.subject,
        senderName: email.sender.name
    )

    UndoActionManager.shared.schedule(
        label: "Snoozed",
        onConfirm: {
            SnoozeStore.shared.add(item)
            Task { await vm.archive(msgID) } // Remove from inbox
        },
        onUndo: { if let msg = removed { vm.restoreOptimistically(msg) } }
    )
}

func unsnoozeEmail(messageId: String, accountID: String) {
    SnoozeStore.shared.remove(messageId: messageId, accountID: accountID)
    Task {
        try? await GmailMessageService.shared.modifyLabels(
            id: messageId,
            add: [GmailSystemLabel.inbox],
            remove: [],
            accountID: accountID
        )
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/ViewModels/EmailActionCoordinator.swift
git commit -m "feat: wire snooze actions through EmailActionCoordinator"
```

---

### Task 16: Scheduled Send — Create ScheduledSendStore

**Files:**
- Create: `Serif/Services/ScheduledSendStore.swift`

- [ ] **Step 1: Create scheduled send persistence**

```swift
import Foundation

struct ScheduledSendItem: Codable, Identifiable, Sendable {
    let id: UUID
    let draftId: String
    let accountID: String
    let scheduledTime: Date
    let subject: String
    let recipients: [String]

    init(
        id: UUID = UUID(),
        draftId: String,
        accountID: String,
        scheduledTime: Date,
        subject: String = "",
        recipients: [String] = []
    ) {
        self.id = id
        self.draftId = draftId
        self.accountID = accountID
        self.scheduledTime = scheduledTime
        self.subject = subject
        self.recipients = recipients
    }
}

private struct ScheduledFileContents: Codable {
    var version: Int = 1
    var items: [ScheduledSendItem] = []
}

@Observable
@MainActor
final class ScheduledSendStore {
    static let shared = ScheduledSendStore()
    private init() {}

    private(set) var items: [ScheduledSendItem] = []

    func load(accountID: String) {
        let url = fileURL(for: accountID)
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(ScheduledFileContents.self, from: data) else {
            items = []
            return
        }
        items = contents.items.filter { $0.accountID == accountID }
    }

    func add(_ item: ScheduledSendItem) {
        items.append(item)
        save(accountID: item.accountID)
    }

    func remove(draftId: String, accountID: String) {
        items.removeAll { $0.draftId == draftId && $0.accountID == accountID }
        save(accountID: accountID)
    }

    func dueItems() -> [ScheduledSendItem] {
        let now = Date()
        return items.filter { $0.scheduledTime <= now }
    }

    private func save(accountID: String) {
        let url = fileURL(for: accountID)
        let contents = ScheduledFileContents(version: 1, items: items.filter { $0.accountID == accountID })
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }

    private func fileURL(for accountID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.genyus.serif.app/mail-cache/\(accountID)/scheduled.json")
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/ScheduledSendStore.swift
git commit -m "feat: add ScheduledSendStore for persisting scheduled sends"
```

---

### Task 17: Scheduled Send — Create ScheduledSendMonitor (Unified with Snooze)

**Files:**
- Modify: `Serif/Services/SnoozeMonitor.swift` (rename concept to `BackgroundTimerMonitor` or keep as `SnoozeMonitor` with scheduled send logic)

- [ ] **Step 0: Add `sendDraft` to GmailDraftService (prerequisite)**

`GmailDraftService` does not have a `sendDraft` method. Add it to `Serif/Services/Gmail/GmailDraftService.swift`:

```swift
@concurrent func sendDraft(draftId: String, accountID: String) async throws(GmailAPIError) {
    struct SendDraftRequest: Encodable { let id: String }
    let body = try JSONEncoder().encode(SendDraftRequest(id: draftId))
    let _: GmailMessage = try await GmailAPIClient.shared.request(
        path: "/users/me/drafts/send",
        method: "POST",
        body: body,
        contentType: "application/json",
        accountID: accountID
    )
}
```

- [ ] **Step 1: Add scheduled send checking to SnoozeMonitor**

Add a `checkScheduledSends()` method and call it from the timer alongside `checkExpired()`:

```swift
private func checkExpired() async {
    await checkSnoozedItems()
    await checkScheduledSends()
}

private func checkSnoozedItems() async {
    let expired = SnoozeStore.shared.expiredItems()
    for item in expired {
        do {
            try await GmailMessageService.shared.modifyLabels(
                id: item.messageId,
                add: item.originalLabelIds.isEmpty ? [GmailSystemLabel.inbox] : item.originalLabelIds,
                remove: [],
                accountID: item.accountID
            )
            SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
        } catch {
            if case .httpError(404, _) = error as? GmailAPIError {
                SnoozeStore.shared.remove(messageId: item.messageId, accountID: item.accountID)
            }
        }
    }
}

private func checkScheduledSends() async {
    let due = ScheduledSendStore.shared.dueItems()
    for item in due {
        do {
            try await GmailDraftService.shared.sendDraft(draftId: item.draftId, accountID: item.accountID)
            ScheduledSendStore.shared.remove(draftId: item.draftId, accountID: item.accountID)
            ToastManager.shared.show(message:"Scheduled email sent: \(item.subject)")
        } catch {
            if case .httpError(404, _) = error as? GmailAPIError {
                ScheduledSendStore.shared.remove(draftId: item.draftId, accountID: item.accountID)
            }
            // Other errors: retry next cycle
        }
    }
}
```

Note: Verify `GmailDraftService` has a `sendDraft(draftId:accountID:)` method. If not, add one that calls `POST /users/me/drafts/send` with `{"id": draftId}`.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/SnoozeMonitor.swift
git commit -m "feat: unify snooze and scheduled send monitoring in SnoozeMonitor"
```

---

### Task 18: Scheduled Send — Add `scheduleSend(at:)` to ComposeViewModel

**Files:**
- Modify: `Serif/ViewModels/ComposeViewModel.swift`

- [ ] **Step 1: Add scheduleSend method**

Add after `send()` (line 60):

```swift
// MARK: - Schedule Send

func scheduleSend(at scheduledDate: Date) async {
    isSending = true
    error = nil
    defer { isSending = false }

    // Ensure draft exists on server
    await saveDraft()
    guard let draftID = gmailDraftID else {
        error = "Failed to save draft for scheduling"
        return
    }

    let item = ScheduledSendItem(
        draftId: draftID,
        accountID: accountID,
        scheduledTime: scheduledDate,
        subject: subject,
        recipients: splitAddresses(to)
    )
    ScheduledSendStore.shared.add(item)
    isSent = true
    ToastManager.shared.show(message:"Email scheduled")
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/ViewModels/ComposeViewModel.swift
git commit -m "feat: add scheduleSend(at:) to ComposeViewModel"
```

---

### Task 19: Scheduled Send — Create ScheduleSendButton

**Files:**
- Create: `Serif/Views/Compose/ScheduleSendButton.swift`

- [ ] **Step 1: Create split send button**

```swift
import SwiftUI

struct ScheduleSendButton: View {
    let onSend: () -> Void
    let onSchedule: (Date) -> Void
    let isSending: Bool

    @State private var showSchedulePicker = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSend) {
                if isSending {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Text("Send")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending)

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 2)

            Menu {
                Button {
                    showSchedulePicker = true
                } label: {
                    Label("Schedule Send", systemImage: "calendar.badge.clock")
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .popover(isPresented: $showSchedulePicker) {
                SnoozePickerView(title: "Schedule for...") { date in
                    showSchedulePicker = false
                    onSchedule(date)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/Compose/ScheduleSendButton.swift
git commit -m "feat: add ScheduleSendButton with split send/schedule UI"
```

---

### Task 20: Command Palette — Create Command Model

**Files:**
- Create: `Serif/Models/Command.swift`

- [ ] **Step 1: Create command model**

```swift
import Foundation

struct Command: Identifiable, Sendable {
    let id: String  // Stable string ID (e.g., "action.compose", "folder.inbox")
    let title: String
    let icon: String
    let shortcut: String?
    let category: Category
    let action: @Sendable @MainActor () -> Void

    enum Category: String, CaseIterable, Sendable {
        case actions = "Actions"
        case folders = "Folders"
        case labels = "Labels"
        case accounts = "Accounts"
        case settings = "Settings"
    }

    /// Fuzzy match: substring match on title
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query)
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Models/Command.swift
git commit -m "feat: add Command model for command palette"
```

---

### Task 21: Command Palette — Create CommandPaletteViewModel

**Files:**
- Create: `Serif/ViewModels/CommandPaletteViewModel.swift`

- [ ] **Step 1: Create view model with command indexing and fuzzy search**

```swift
import SwiftUI

@Observable
@MainActor
final class CommandPaletteViewModel {
    var query = ""
    var isVisible = false
    var selectedIndex = 0

    private var allCommands: [Command] = []
    private var recentCommandIDs: [String] = []

    var filteredCommands: [Command] {
        let matched = query.isEmpty ? allCommands : allCommands.filter { $0.matches(query) }
        return Array(matched.prefix(10))
    }

    var groupedCommands: [(category: Command.Category, commands: [Command])] {
        let grouped = Dictionary(grouping: filteredCommands, by: \.category)
        return Command.Category.allCases.compactMap { category in
            guard let commands = grouped[category], !commands.isEmpty else { return nil }
            return (category: category, commands: commands)
        }
    }

    func buildCommands(coordinator: AppCoordinator) {
        var commands: [Command] = []

        // Actions
        commands.append(Command(id: "action.compose", title: "Compose New Message", icon: "square.and.pencil", shortcut: "\u{2318}N", category: .actions) {
            coordinator.composeNewEmail()
        })
        commands.append(Command(id: "action.refresh", title: "Refresh", icon: "arrow.clockwise", shortcut: "\u{21E7}\u{2318}R", category: .actions) {
            Task { await coordinator.loadCurrentFolder() }
        })
        commands.append(Command(id: "action.search", title: "Search", icon: "magnifyingglass", shortcut: "\u{2318}F", category: .actions) {
            coordinator.searchFocusTrigger = true
        })

        // Folders
        for folder in Folder.allCases where folder != .labels {
            commands.append(Command(id: "folder.\(folder.rawValue)", title: folder.rawValue, icon: folder.icon, shortcut: nil, category: .folders) {
                coordinator.selectedFolder = folder
            })
        }

        // Settings — open via NSApp standard Settings action
        commands.append(Command(id: "settings.open", title: "Settings", icon: "gear", shortcut: "\u{2318},", category: .settings) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        })
        commands.append(Command(id: "settings.shortcuts", title: "Keyboard Shortcuts", icon: "keyboard", shortcut: nil, category: .settings) {
            coordinator.panelCoordinator.showHelp = true
        })

        allCommands = commands
    }

    func execute(_ command: Command) {
        command.action()
        recentCommandIDs = ([command.id] + recentCommandIDs).prefix(5).map { $0 }
        dismiss()
    }

    func toggle() {
        isVisible.toggle()
        if isVisible {
            query = ""
            selectedIndex = 0
        }
    }

    func dismiss() {
        isVisible = false
        query = ""
        selectedIndex = 0
    }

    func moveUp() {
        let total = filteredCommands.count
        guard total > 0 else { return }
        selectedIndex = (selectedIndex - 1 + total) % total
    }

    func moveDown() {
        let total = filteredCommands.count
        guard total > 0 else { return }
        selectedIndex = (selectedIndex + 1) % total
    }

    func executeSelected() {
        guard selectedIndex < filteredCommands.count else { return }
        execute(filteredCommands[selectedIndex])
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/ViewModels/CommandPaletteViewModel.swift
git commit -m "feat: add CommandPaletteViewModel with fuzzy search"
```

---

### Task 22: Command Palette — Create CommandPaletteView

**Files:**
- Create: `Serif/Views/Common/CommandPaletteView.swift`

- [ ] **Step 1: Create the floating overlay**

```swift
import SwiftUI

struct CommandPaletteView: View {
    @Bindable var viewModel: CommandPaletteViewModel

    var body: some View {
        if viewModel.isVisible {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { viewModel.dismiss() }

                VStack(spacing: 0) {
                    searchField
                    Divider()
                    resultsList
                }
                .frame(width: 500, maxHeight: 400)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 20, y: 10)
                .padding(.top, 80)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .transition(.opacity)
            .onKeyPress(.escape) {
                viewModel.dismiss()
                return .handled
            }
            .onKeyPress(.upArrow) {
                viewModel.moveUp()
                return .handled
            }
            .onKeyPress(.downArrow) {
                viewModel.moveDown()
                return .handled
            }
            .onKeyPress(.return) {
                viewModel.executeSelected()
                return .handled
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Type a command...", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.title3)
        }
        .padding(12)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let flat = viewModel.filteredCommands
                ForEach(viewModel.groupedCommands, id: \.category) { group in
                    Text(group.category.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    ForEach(group.commands) { command in
                        let index = flat.firstIndex(where: { $0.id == command.id }) ?? 0
                        commandRow(command, isSelected: index == viewModel.selectedIndex)
                            .onTapGesture { viewModel.execute(command) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func commandRow(_ command: Command, isSelected: Bool) -> some View {
        HStack {
            Image(systemName: command.icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(command.title)
            Spacer()
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/Common/CommandPaletteView.swift
git commit -m "feat: add CommandPaletteView overlay with keyboard navigation"
```

---

### Task 23: Command Palette — Integrate into ContentView + SerifCommands

**Files:**
- Modify: `Serif/ContentView.swift`
- Modify: `Serif/Views/Common/SerifCommands.swift`

- [ ] **Step 1: Add command palette state and overlay to ContentView**

Add a `@State` for the command palette VM at line 5 (after `coordinator`):

```swift
@State private var commandPalette = CommandPaletteViewModel()
```

Add the overlay in the `ZStack` at line 49, after `SlidePanelsOverlay` (line 155):

```swift
CommandPaletteView(viewModel: commandPalette)
    .zIndex(10)
```

Add a lifecycle hook to build commands (in `withLifecycle`, after line 264):

```swift
.onAppear { commandPalette.buildCommands(coordinator: coordinator) }
```

Add Cmd+K key handler to the ZStack (after `SlidePanelsOverlay`):

```swift
.onKeyPress("k", modifiers: .command) {
    // Don't open palette when compose is active (WKWebView uses Cmd+K for link insertion)
    guard !coordinator.isComposeActive else { return .ignored }
    commandPalette.toggle()
    return .handled
}
```

Note: `isComposeActive` should be a property on `AppCoordinator` indicating any compose sheet/panel is open. The implementing engineer should check how compose state is tracked (likely `coordinator.panelCoordinator` has a compose-related flag) and adapt accordingly.

- [ ] **Step 2: Register Cmd+K in SerifCommands**

Add to the `mailboxMenu` in `SerifCommands.swift` (after the Search button, line 120):

```swift
Divider()

Button {
    // Handled by ContentView's onKeyPress — this entry is for menu bar visibility
} label: {
    Label("Command Palette", systemImage: "command")
}
.keyboardShortcut("k", modifiers: .command)
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Serif/ContentView.swift Serif/Views/Common/SerifCommands.swift
git commit -m "feat: integrate command palette with Cmd+K shortcut"
```

---

### Task 24: Offline Action Queue — Create OfflineAction Model

**Files:**
- Create: `Serif/Models/OfflineAction.swift`

- [ ] **Step 1: Create the offline action model**

```swift
import Foundation

struct OfflineAction: Codable, Identifiable, Sendable {
    let id: UUID
    let action: ActionType
    let messageIds: [String]
    let accountID: String
    let timestamp: Date
    let params: [String: String]

    init(
        id: UUID = UUID(),
        action: ActionType,
        messageIds: [String],
        accountID: String,
        timestamp: Date = Date(),
        params: [String: String] = [:]
    ) {
        self.id = id
        self.action = action
        self.messageIds = messageIds
        self.accountID = accountID
        self.timestamp = timestamp
        self.params = params
    }

    enum ActionType: String, Codable, Sendable {
        case archive
        case trash
        case star
        case unstar
        case markRead
        case markUnread
        case addLabel
        case removeLabel
        case spam
        case moveToInbox
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Models/OfflineAction.swift
git commit -m "feat: add OfflineAction model for offline mutation queue"
```

---

### Task 25: Offline Action Queue — Create OfflineActionQueue Service

**Files:**
- Create: `Serif/Services/OfflineActionQueue.swift`

- [ ] **Step 1: Create the queue service**

```swift
import Foundation

@Observable
@MainActor
final class OfflineActionQueue {
    static let shared = OfflineActionQueue()
    private init() {}

    private(set) var pendingActions: [OfflineAction] = []
    private(set) var isDraining = false
    private var drainTask: Task<Void, Never>?

    var pendingCount: Int { pendingActions.count }

    func enqueue(_ action: OfflineAction) {
        pendingActions.append(action)
        save(accountID: action.accountID)
    }

    func load(accountID: String) {
        let url = fileURL(for: accountID)
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(OfflineQueueFileContents.self, from: data) else {
            return
        }
        pendingActions = contents.actions
    }

    func startDraining() {
        guard !isDraining, !pendingActions.isEmpty else { return }
        isDraining = true

        drainTask = Task { [weak self] in
            guard let self else { return }
            var succeeded = 0

            while let action = self.pendingActions.first {
                do {
                    try await self.executeAction(action)
                    self.pendingActions.removeFirst()
                    self.save(accountID: action.accountID)
                    succeeded += 1
                } catch {
                    if case .httpError(404, _) = error as? GmailAPIError {
                        // Message gone — skip
                        self.pendingActions.removeFirst()
                        self.save(accountID: action.accountID)
                    } else if case .unauthorized = error as? GmailAPIError {
                        // Stop draining — need re-auth
                        break
                    } else {
                        // Retry later
                        break
                    }
                }
            }

            self.isDraining = false
            if succeeded > 0 {
                ToastManager.shared.show(message:"Synced \(succeeded) action\(succeeded == 1 ? "" : "s")")
            }
        }
    }

    private func executeAction(_ action: OfflineAction) async throws {
        for msgId in action.messageIds {
            switch action.action {
            case .archive:
                try await GmailMessageService.shared.archiveMessage(id: msgId, accountID: action.accountID)
            case .trash:
                try await GmailMessageService.shared.trashMessage(id: msgId, accountID: action.accountID)
            case .star:
                try await GmailMessageService.shared.setStarred(true, id: msgId, accountID: action.accountID)
            case .unstar:
                try await GmailMessageService.shared.setStarred(false, id: msgId, accountID: action.accountID)
            case .markRead:
                try await GmailMessageService.shared.markAsRead(id: msgId, accountID: action.accountID)
            case .markUnread:
                try await GmailMessageService.shared.markAsUnread(id: msgId, accountID: action.accountID)
            case .addLabel:
                if let labelId = action.params["labelId"] {
                    try await GmailMessageService.shared.modifyLabels(id: msgId, add: [labelId], remove: [], accountID: action.accountID)
                }
            case .removeLabel:
                if let labelId = action.params["labelId"] {
                    try await GmailMessageService.shared.modifyLabels(id: msgId, add: [], remove: [labelId], accountID: action.accountID)
                }
            case .spam:
                try await GmailMessageService.shared.spamMessage(id: msgId, accountID: action.accountID)
            case .moveToInbox:
                try await GmailMessageService.shared.modifyLabels(id: msgId, add: [GmailSystemLabel.inbox], remove: [], accountID: action.accountID)
            }
        }
    }

    private func save(accountID: String) {
        let url = fileURL(for: accountID)
        let contents = OfflineQueueFileContents(version: 1, actions: pendingActions.filter { $0.accountID == accountID })
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(contents).write(to: url, options: .atomic)
    }

    private func fileURL(for accountID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.genyus.serif.app/offline-queue/\(accountID).json")
    }
}

private struct OfflineQueueFileContents: Codable {
    var version: Int = 1
    var actions: [OfflineAction] = []
}
```

- [ ] **Step 2: Wire NetworkMonitor to trigger drain on reconnect**

Add `onChange` in ContentView's `withLifecycle` method to drain on reconnect:

```swift
.onChange(of: NetworkMonitor.shared.isConnected) { _, connected in
    if connected { OfflineActionQueue.shared.startDraining() }
}
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Serif/Services/OfflineActionQueue.swift Serif/Models/OfflineAction.swift
git commit -m "feat: add OfflineActionQueue with auto-drain on reconnect"
```

---

### Task 26: Offline Queue — Route Actions Through Queue When Offline

**Files:**
- Modify: `Serif/ViewModels/EmailActionCoordinator.swift`

- [ ] **Step 1: Add offline routing to EmailActionCoordinator**

Update `archiveEmail` (line 16) to check connectivity before executing. Apply the same pattern to `deleteEmail`, `toggleStarEmail`, `markUnreadEmail`, `markSpamEmail`:

```swift
func archiveEmail(_ email: Email, selectNext: (Email?) -> Void) {
    guard let msgID = email.gmailMessageID else { return }
    let vm = mailboxViewModel
    let removed = vm.removeOptimistically(msgID)
    selectNext(nil)

    if NetworkMonitor.shared.isConnected {
        UndoActionManager.shared.schedule(
            label: "Archived",
            onConfirm: { Task { await vm.archive(msgID) } },
            onUndo:    { if let msg = removed { vm.restoreOptimistically(msg) } }
        )
    } else {
        OfflineActionQueue.shared.enqueue(OfflineAction(
            action: .archive, messageIds: [msgID], accountID: vm.accountID
        ))
        ToastManager.shared.show(message:"Archived (will sync when online)")
    }
}
```

Apply the same pattern to all other action methods. For brevity, the implementing engineer should follow this pattern for: `deleteEmail`, `toggleStarEmail`, `markUnreadEmail`, `markSpamEmail`, `moveToInboxEmail`.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/ViewModels/EmailActionCoordinator.swift
git commit -m "feat: route email actions through OfflineActionQueue when offline"
```

---

### Task 27: Offline Queue — Add Offline Banner to ListPaneView

**Files:**
- Modify: `Serif/Views/EmailList/ListPaneView.swift`

- [ ] **Step 1: Add offline banner**

In the `body` computed property, add a banner above the email list:

```swift
var body: some View {
    VStack(spacing: 0) {
        if !NetworkMonitor.shared.isConnected {
            HStack {
                Image(systemName: "wifi.slash")
                Text("You're offline. Changes will sync when connected.")
                if OfflineActionQueue.shared.pendingCount > 0 {
                    Text("(\(OfflineActionQueue.shared.pendingCount) pending)")
                        .fontWeight(.medium)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.yellow.opacity(0.1))
        }

        if selectedFolder == .inbox {
            CategoryTabBar(
                selectedCategory: $selectedCategory,
                unreadCounts: mailboxViewModel.categoryUnreadCounts
            )
            Divider()
        }
        emailList
    }
    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/EmailList/ListPaneView.swift
git commit -m "feat: add offline banner with pending action count"
```

---

### Task 28: Nudging — Add Nudge Text to EmailRowView

**Files:**
- Modify: `Serif/Views/EmailList/EmailRowView.swift`

- [ ] **Step 1: Add nudge logic and display**

Add a computed property to determine if the email should show a nudge:

```swift
private var nudgeText: String? {
    guard email.folder == .inbox,
          !email.isFromMailingList,
          email.threadMessageCount <= 1 || !hasReply else { return nil }
    let daysAgo = Calendar.current.dateComponents([.day], from: email.date, to: Date()).day ?? 0
    guard daysAgo >= 3 else { return nil }
    return "Received \(daysAgo) days ago"
}

// hasReply should be passed in or computed from thread data
```

Add the nudge text below the snippet in the email row:

```swift
if let nudge = nudgeText {
    Text(nudge)
        .font(.caption2)
        .foregroundStyle(.orange)
}
```

Note: Whether the user has replied in the thread requires thread-level analysis. For the initial implementation, base this on `threadMessageCount == 1` (single message, no reply yet). A more sophisticated check can be added later.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/EmailList/EmailRowView.swift
git commit -m "feat: add nudge text for emails needing attention"
```

---

## Chunk 3: Phase 3 — "Intelligence" (Smart Reply + Enhanced AI + Classification + Filters)

### Task 29: Smart Reply — Create SmartReplyProvider

**Files:**
- Create: `Serif/Services/SmartReplyProvider.swift`

- [ ] **Step 1: Create the Foundation Models smart reply service**

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct SmartReplies {
    @Guide(description: "2-3 short, contextual reply options for this email. Each should be a complete sentence or two, matching a professional tone.")
    var replies: [String]
}
#endif

@MainActor
final class SmartReplyProvider {
    static let shared = SmartReplyProvider()
    private init() {}

    private var cache: [String: [String]] = [:] // threadId -> replies

    func cachedReplies(for threadId: String) -> [String]? {
        cache[threadId]
    }

    func invalidate(threadId: String) {
        cache.removeValue(forKey: threadId)
    }

    func generateReplies(
        subject: String,
        senderName: String,
        body: String,
        threadId: String
    ) async -> [String] {
        if let cached = cache[threadId] { return cached }

        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            do {
                guard SystemLanguageModel.default.availability == .available else { return [] }

                let instructions = Instructions("""
                Generate 2-3 short reply suggestions for the email below. \
                Each reply should be 1-2 sentences, professional but friendly. \
                Vary the tone: one positive/agreeable, one asking for clarification, one brief acknowledgment. \
                Use the same language as the email.
                """)
                let session = LanguageModelSession(instructions: instructions)

                // Truncate body to fit 4K context (~2500 tokens ≈ 10000 chars)
                let truncatedBody = String(body.cleanedForAI().prefix(10000))
                let prompt = "From: \(senderName)\nSubject: \(subject)\n\n\(truncatedBody)"

                let response = try await session.respond(to: prompt, generating: SmartReplies.self)
                let replies = Array(response.replies.prefix(3))
                cache[threadId] = replies
                return replies
            } catch {
                return []
            }
            #else
            return []
            #endif
        } else {
            return []
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/SmartReplyProvider.swift
git commit -m "feat: add SmartReplyProvider using Foundation Models @Generable"
```

---

### Task 30: Smart Reply — Create SmartReplyChipsView

**Files:**
- Create: `Serif/Views/EmailDetail/SmartReplyChipsView.swift`

- [ ] **Step 1: Create tappable suggestion chips**

```swift
import SwiftUI

struct SmartReplyChipsView: View {
    let suggestions: [String]
    let onSelect: (String) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            onSelect(suggestion)
                        } label: {
                            Text(suggestion)
                                .font(.caption)
                                .lineLimit(2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.1))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 4)
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/EmailDetail/SmartReplyChipsView.swift
git commit -m "feat: add SmartReplyChipsView for tappable reply suggestions"
```

---

### Task 31: Smart Reply — Integrate into ReplyBarView

**Files:**
- Modify: `Serif/Views/EmailDetail/ReplyBarView.swift`
- Modify: `Serif/ViewModels/EmailDetailViewModel.swift`

- [ ] **Step 1: Add smart reply generation trigger to EmailDetailViewModel**

Add properties and trigger method:

```swift
var smartReplySuggestions: [String] = []

func loadSmartReplies(for email: Email) {
    guard let threadId = email.gmailThreadID else { return }
    if let cached = SmartReplyProvider.shared.cachedReplies(for: threadId) {
        smartReplySuggestions = cached
        return
    }
    Task {
        let replies = await SmartReplyProvider.shared.generateReplies(
            subject: email.subject,
            senderName: email.sender.name,
            body: email.body,
            threadId: threadId
        )
        smartReplySuggestions = replies
    }
}
```

- [ ] **Step 2: Embed chips above the reply bar in ReplyBarView**

Add `SmartReplyChipsView` above the existing reply bar content. The chips should call the existing reply initiation callback with the selected text pre-filled:

```swift
SmartReplyChipsView(
    suggestions: detailVM.smartReplySuggestions,
    onSelect: { suggestion in
        onStartReply?(suggestion)
    }
)
```

Note: The exact integration depends on `ReplyBarView`'s current structure. The implementing engineer should read `ReplyBarView.swift` and add the chips above the reply button area.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Serif/Views/EmailDetail/ReplyBarView.swift Serif/ViewModels/EmailDetailViewModel.swift
git commit -m "feat: integrate smart reply chips into reply bar"
```

---

### Task 32: Enhanced Summarization — Add `@Generable EmailInsight`

**Files:**
- Modify: `Serif/Services/SummaryService.swift`

- [ ] **Step 1: Add EmailInsight struct and structured generation**

Add after the imports (line 4):

```swift
#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct EmailInsight {
    @Guide(description: "2-3 sentence summary of the email content")
    var summary: String

    @Guide(description: "Required action from the recipient, if any. nil if purely informational")
    var actionNeeded: String?

    @Guide(description: "Deadline or time-sensitive date mentioned, if any")
    var deadline: String?

    @Guide(description: "Sentiment: positive, neutral, negative, or urgent")
    var sentiment: String
}
#endif
```

Add a new method for structured insight generation:

```swift
#if canImport(FoundationModels)
@available(macOS 26.0, *)
func insight(for email: Email) -> AsyncStream<EmailInsightSnapshot> {
    AsyncStream { continuation in
        let task = Task {
            do {
                let instructions = Instructions("""
                Analyze this email and provide a structured summary. \
                Focus on what matters: what is it about, what action is needed, any deadlines. \
                Use the same language as the email.
                """)
                let session = LanguageModelSession(instructions: instructions)

                let body = cleanedPreview(from: email)
                // Truncate for 4K context
                let truncated = String(body.prefix(10000))
                let prompt = "From: \(email.sender.name)\nSubject: \(email.subject)\n\n\(truncated)"

                let response = session.streamResponse(to: prompt, generating: EmailInsight.self)
                for try await partial in response {
                    continuation.yield(EmailInsightSnapshot(
                        summary: partial.summary,
                        actionNeeded: partial.actionNeeded,
                        deadline: partial.deadline,
                        sentiment: partial.sentiment
                    ))
                }
                continuation.finish()
            } catch {
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
#endif
```

Add a plain-Swift snapshot struct (outside `#if canImport`):

```swift
struct EmailInsightSnapshot: Sendable {
    var summary: String?
    var actionNeeded: String?
    var deadline: String?
    var sentiment: String?
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/SummaryService.swift
git commit -m "feat: add @Generable EmailInsight with streaming structured output"
```

---

### Task 33: AI Classification — Create EmailTags Model

**Files:**
- Create: `Serif/Models/EmailTags.swift`

- [ ] **Step 1: Create the classification tags model**

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedEmailTags {
    @Guide(description: "true if the sender expects a reply from the reader")
    var needsReply: Bool

    @Guide(description: "true if this is purely informational with no action needed")
    var fyiOnly: Bool

    @Guide(description: "true if a specific deadline or due date is mentioned")
    var hasDeadline: Bool

    @Guide(description: "true if this involves money: invoice, receipt, payment, billing")
    var financial: Bool
}
#endif

struct EmailTags: Codable, Sendable, Equatable {
    var needsReply: Bool = false
    var fyiOnly: Bool = false
    var hasDeadline: Bool = false
    var financial: Bool = false

    var activeTags: [(label: String, color: String)] {
        var tags: [(String, String)] = []
        if needsReply  { tags.append(("Reply needed", "blue")) }
        if hasDeadline { tags.append(("Deadline", "red")) }
        if financial   { tags.append(("Financial", "green")) }
        if fyiOnly     { tags.append(("FYI", "gray")) }
        return tags
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Models/EmailTags.swift
git commit -m "feat: add EmailTags model with @Generable classification"
```

---

### Task 34: AI Classification — Create EmailClassifier Service

**Files:**
- Create: `Serif/Services/EmailClassifier.swift`

- [ ] **Step 1: Create the classification service**

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class EmailClassifier {
    static let shared = EmailClassifier()
    private init() {}

    private var tagCache: [String: EmailTags] = [:] // messageId -> tags

    func cachedTags(for messageId: String) -> EmailTags? {
        tagCache[messageId]
    }

    func classifyBatch(_ emails: [Email]) async {
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            do {
                guard SystemLanguageModel.default.availability == .available else { return }

                for email in emails.prefix(10) {
                    guard let msgId = email.gmailMessageID,
                          tagCache[msgId] == nil else { continue }

                    let instructions = Instructions("Classify this email with boolean tags.")
                    let session = LanguageModelSession(instructions: instructions, model: SystemLanguageModel(useCase: .contentTagging))

                    let body = String(email.body.cleanedForAI().prefix(5000))
                    let prompt = "Subject: \(email.subject)\nFrom: \(email.sender.name)\n\n\(body)"

                    let result = try await session.respond(to: prompt, generating: GeneratedEmailTags.self)
                    let tags = EmailTags(
                        needsReply: result.needsReply,
                        fyiOnly: result.fyiOnly,
                        hasDeadline: result.hasDeadline,
                        financial: result.financial
                    )
                    tagCache[msgId] = tags
                }
            } catch {
                // Classification is best-effort — silently fail
            }
            #endif
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/EmailClassifier.swift
git commit -m "feat: add EmailClassifier for Foundation Models email tagging"
```

---

### Task 35: AI Classification — Show Tag Badges on EmailRowView

**Files:**
- Modify: `Serif/Views/EmailList/EmailRowView.swift`

- [ ] **Step 1: Add tag badges to email row**

Add tag display logic after the existing label chips area:

```swift
// AI classification tags
if let tags = EmailClassifier.shared.cachedTags(for: email.gmailMessageID ?? "") {
    HStack(spacing: 4) {
        ForEach(tags.activeTags, id: \.label) { tag in
            Text(tag.label)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(tagColor(tag.color).opacity(0.15))
                .foregroundStyle(tagColor(tag.color))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}
```

Add helper:

```swift
private func tagColor(_ name: String) -> Color {
    switch name {
    case "blue":  return .blue
    case "red":   return .red
    case "green": return .green
    default:      return .secondary
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/EmailList/EmailRowView.swift
git commit -m "feat: show AI classification tag badges on email rows"
```

---

### Task 35a: AI Classification — Wire into MessageFetchService and MailCacheStore

**Files:**
- Modify: `Serif/Services/MessageFetchService.swift`
- Modify: `Serif/Services/MailCacheStore.swift`

- [ ] **Step 1: Add tag persistence to MailCacheStore**

Add a `tags` property alongside existing message cache data. Store/load `EmailTags` keyed by message ID:

```swift
private var tagStore: [String: EmailTags] = [] // messageId -> tags

func saveTags(_ tags: EmailTags, for messageId: String, accountID: String) {
    tagStore[messageId] = tags
    saveTagsToDisk(accountID: accountID)
}

func loadTags(for messageId: String) -> EmailTags? {
    tagStore[messageId]
}
```

Persist to `~/Library/Application Support/com.genyus.serif.app/mail-cache/{accountID}/tags.json` with `version: Int` field.

- [ ] **Step 2: Call EmailClassifier from MessageFetchService**

In `MessageFetchService.analyzeInBackground()` (or equivalent background analysis method), add classification call:

```swift
// After existing subscription detection
await EmailClassifier.shared.classifyBatch(newEmails)

// Persist results
for email in newEmails {
    if let msgId = email.gmailMessageID,
       let tags = EmailClassifier.shared.cachedTags(for: msgId) {
        MailCacheStore.shared.saveTags(tags, for: msgId, accountID: accountID)
    }
}
```

- [ ] **Step 3: Update EmailClassifier to check MailCacheStore first**

In `EmailClassifier.classifyBatch()`, before calling the model, check persistent cache:

```swift
guard let msgId = email.gmailMessageID,
      tagCache[msgId] == nil else { continue }

// Check disk cache first
if let persisted = MailCacheStore.shared.loadTags(for: msgId) {
    tagCache[msgId] = persisted
    continue
}
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Serif/Services/MessageFetchService.swift Serif/Services/MailCacheStore.swift Serif/Services/EmailClassifier.swift
git commit -m "feat: wire email classification into fetch pipeline with persistent storage"
```

---

### Task 35b: Enhanced Summarization — EmailInsight UI Integration

**Files:**
- Modify: `Serif/Views/EmailList/EmailHoverSummaryView.swift`
- Modify: `Serif/Views/EmailDetail/EmailDetailView.swift`

- [ ] **Step 1: Show structured insight in EmailHoverSummaryView**

Update the hover summary view to show `EmailInsightSnapshot` fields when available. Add action/deadline/sentiment badges below the summary text:

```swift
// After the existing summary text
if let insight = summaryVM.insight {
    if let action = insight.actionNeeded {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(action)
                .font(.caption)
        }
    }
    if let deadline = insight.deadline {
        HStack(spacing: 4) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.red)
            Text(deadline)
                .font(.caption)
        }
    }
    if let sentiment = insight.sentiment {
        Text(sentiment.capitalized)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(sentimentColor(sentiment).opacity(0.15))
            .foregroundStyle(sentimentColor(sentiment))
            .clipShape(Capsule())
    }
}
```

- [ ] **Step 2: Show insight card in EmailDetailView**

Add a summary insight card below the email header in the detail view. Wire it to `SummaryService.insight(for:)` with the streaming output.

The implementing engineer should read `EmailDetailView.swift` to find the appropriate insertion point (after the sender info, before the email body).

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Serif/Views/EmailList/EmailHoverSummaryView.swift Serif/Views/EmailDetail/EmailDetailView.swift
git commit -m "feat: show structured EmailInsight in hover summary and detail view"
```

---

### Task 35c: Enhanced Summarization — Chain Summarization for Long Threads

**Files:**
- Modify: `Serif/Services/SummaryService.swift`

- [ ] **Step 1: Add chain summarization method**

Add a method that handles multi-message threads by summarizing in stages:

```swift
#if canImport(FoundationModels)
@available(macOS 26.0, *)
func threadInsight(messages: [Email]) -> AsyncStream<EmailInsightSnapshot> {
    AsyncStream { continuation in
        let task = Task {
            do {
                let instructions = Instructions("""
                Analyze this email thread and provide a structured summary. \
                Focus on the most recent developments and any required actions. \
                Use the same language as the emails.
                """)
                let session = LanguageModelSession(instructions: instructions)

                // Chain summarization: if >3 messages, summarize older ones first
                let context: String
                if messages.count > 3 {
                    let olderMessages = messages.dropLast(2)
                    let olderText = olderMessages.map { msg in
                        "From: \(msg.sender.name)\n\(msg.body.cleanedForAI().prefix(2000))"
                    }.joined(separator: "\n---\n")

                    // Summarize older messages into a paragraph
                    let summaryResponse = try await session.respond(
                        to: "Summarize this email history in one paragraph:\n\n\(String(olderText.prefix(8000)))"
                    )
                    let recentText = messages.suffix(2).map { msg in
                        "From: \(msg.sender.name)\nSubject: \(msg.subject)\n\(msg.body.cleanedForAI().prefix(3000))"
                    }.joined(separator: "\n---\n")

                    context = "Earlier context: \(summaryResponse.content)\n\nRecent messages:\n\(recentText)"
                } else {
                    context = messages.map { msg in
                        "From: \(msg.sender.name)\nSubject: \(msg.subject)\n\(msg.body.cleanedForAI().prefix(3000))"
                    }.joined(separator: "\n---\n")
                }

                // Truncate to fit 4K context
                let truncated = String(context.prefix(10000))
                let response = session.streamResponse(to: truncated, generating: EmailInsight.self)
                for try await partial in response {
                    continuation.yield(EmailInsightSnapshot(
                        summary: partial.summary,
                        actionNeeded: partial.actionNeeded,
                        deadline: partial.deadline,
                        sentiment: partial.sentiment
                    ))
                }
                continuation.finish()
            } catch {
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
#endif
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/SummaryService.swift
git commit -m "feat: add chain summarization for long email threads"
```

---

### Task 36: Gmail Filters — Create GmailFilterService

**Files:**
- Create: `Serif/Services/Gmail/GmailFilterService.swift`

- [ ] **Step 1: Create the Gmail Filters API wrapper**

```swift
import Foundation

struct GmailFilter: Codable, Identifiable, Sendable {
    let id: String
    let criteria: FilterCriteria?
    let action: FilterAction?

    struct FilterCriteria: Codable, Sendable {
        var from: String?
        var to: String?
        var subject: String?
        var query: String?
        var negatedQuery: String?
        var hasAttachment: Bool?
        var excludeChats: Bool?
        var size: Int?
        var sizeComparison: String? // "larger" or "smaller"
    }

    struct FilterAction: Codable, Sendable {
        var addLabelIds: [String]?
        var removeLabelIds: [String]?
        var forward: String?
    }
}

struct GmailFilterListResponse: Codable, Sendable {
    let filter: [GmailFilter]?
}

@MainActor
final class GmailFilterService {
    static let shared = GmailFilterService()
    private init() {}

    private let client = GmailAPIClient.shared

    func listFilters(accountID: String) async throws(GmailAPIError) -> [GmailFilter] {
        let response: GmailFilterListResponse = try await client.request(
            path: "/users/me/settings/filters",
            accountID: accountID
        )
        return response.filter ?? []
    }

    func getFilter(id: String, accountID: String) async throws(GmailAPIError) -> GmailFilter {
        try await client.request(
            path: "/users/me/settings/filters/\(id)",
            accountID: accountID
        )
    }

    func createFilter(criteria: GmailFilter.FilterCriteria, action: GmailFilter.FilterAction, accountID: String) async throws(GmailAPIError) -> GmailFilter {
        struct CreateRequest: Encodable {
            let criteria: GmailFilter.FilterCriteria
            let action: GmailFilter.FilterAction
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(CreateRequest(criteria: criteria, action: action))
        } catch {
            throw .encodingError(error)
        }
        return try await client.request(
            path: "/users/me/settings/filters",
            method: "POST",
            body: body,
            contentType: "application/json",
            accountID: accountID
        )
    }

    func deleteFilter(id: String, accountID: String) async throws(GmailAPIError) {
        _ = try await client.rawRequest(
            path: "/users/me/settings/filters/\(id)",
            method: "DELETE",
            accountID: accountID
        )
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/Gmail/GmailFilterService.swift
git commit -m "feat: add GmailFilterService for filters CRUD"
```

---

### Task 37: Gmail Filters — Create FiltersSettingsView

> **Architecture note:** This view calls `GmailFilterService` directly rather than through a ViewModel. This is consistent with the existing `SettingsView` pattern (which uses `@AppStorage` directly). Settings views in this codebase are simple CRUD wrappers and don't warrant a full ViewModel layer. If filter management grows more complex later, extract a `FiltersViewModel`.

**Files:**
- Create: `Serif/Views/Settings/FiltersSettingsView.swift`

- [ ] **Step 1: Create the filter list view**

```swift
import SwiftUI

struct FiltersSettingsView: View {
    let accountID: String
    @State private var filters: [GmailFilter] = []
    @State private var isLoading = false
    @State private var showEditor = false
    @State private var filterToDelete: GmailFilter?

    var body: some View {
        VStack {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filters.isEmpty {
                ContentUnavailableView("No Filters", systemImage: "line.3.horizontal.decrease.circle", description: Text("Create filters to automatically organize incoming mail."))
            } else {
                List {
                    ForEach(filters) { filter in
                        filterRow(filter)
                    }
                }
            }
        }
        .toolbar {
            Button {
                showEditor = true
            } label: {
                Label("Create Filter", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showEditor) {
            FilterEditorView(accountID: accountID) { _ in
                Task { await loadFilters() }
            }
        }
        .alert("Delete Filter", isPresented: Binding(
            get: { filterToDelete != nil },
            set: { if !$0 { filterToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { filterToDelete = nil }
            Button("Delete", role: .destructive) {
                if let filter = filterToDelete {
                    Task {
                        try? await GmailFilterService.shared.deleteFilter(id: filter.id, accountID: accountID)
                        await loadFilters()
                    }
                }
                filterToDelete = nil
            }
        }
        .task { await loadFilters() }
    }

    private func filterRow(_ filter: GmailFilter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(filterSummary(filter))
                .font(.subheadline)
            Text(actionSummary(filter))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Delete", role: .destructive) { filterToDelete = filter }
        }
    }

    private func loadFilters() async {
        isLoading = true
        defer { isLoading = false }
        filters = (try? await GmailFilterService.shared.listFilters(accountID: accountID)) ?? []
    }

    private func filterSummary(_ filter: GmailFilter) -> String {
        var parts: [String] = []
        if let from = filter.criteria?.from { parts.append("From: \(from)") }
        if let to = filter.criteria?.to { parts.append("To: \(to)") }
        if let subject = filter.criteria?.subject { parts.append("Subject: \(subject)") }
        if let query = filter.criteria?.query { parts.append("Contains: \(query)") }
        if filter.criteria?.hasAttachment == true { parts.append("Has attachment") }
        return parts.isEmpty ? "No criteria" : parts.joined(separator: ", ")
    }

    private func actionSummary(_ filter: GmailFilter) -> String {
        var parts: [String] = []
        if let add = filter.action?.addLabelIds, !add.isEmpty { parts.append("Add labels: \(add.joined(separator: ", "))") }
        if let remove = filter.action?.removeLabelIds {
            if remove.contains("INBOX") { parts.append("Archive") }
            if remove.contains("UNREAD") { parts.append("Mark read") }
        }
        if let fwd = filter.action?.forward { parts.append("Forward to: \(fwd)") }
        return parts.isEmpty ? "No action" : parts.joined(separator: ", ")
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/Settings/FiltersSettingsView.swift
git commit -m "feat: add FiltersSettingsView for Gmail filter management"
```

---

### Task 38: Gmail Filters — Create FilterEditorView

**Files:**
- Create: `Serif/Views/Settings/FilterEditorView.swift`

- [ ] **Step 1: Create the filter editor form**

```swift
import SwiftUI

struct FilterEditorView: View {
    let accountID: String
    let onSave: (GmailFilter) -> Void

    @Environment(\.dismiss) private var dismiss

    // Criteria
    @State private var from = ""
    @State private var to = ""
    @State private var subject = ""
    @State private var query = ""
    @State private var hasAttachment = false

    // Actions
    @State private var shouldArchive = false
    @State private var shouldMarkRead = false
    @State private var shouldStar = false
    @State private var selectedLabelId: String?

    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Match emails that...") {
                    TextField("From", text: $from, prompt: Text("sender@example.com"))
                    TextField("To", text: $to, prompt: Text("recipient@example.com"))
                    TextField("Subject contains", text: $subject)
                    TextField("Has the words", text: $query)
                    Toggle("Has attachment", isOn: $hasAttachment)
                }

                Section("Apply these actions:") {
                    Toggle("Skip inbox (archive)", isOn: $shouldArchive)
                    Toggle("Mark as read", isOn: $shouldMarkRead)
                    Toggle("Star it", isOn: $shouldStar)
                }

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create Filter") {
                    Task { await createFilter() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || (from.isEmpty && to.isEmpty && subject.isEmpty && query.isEmpty))
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 450, height: 450)
    }

    private func createFilter() async {
        isSaving = true
        defer { isSaving = false }

        var criteria = GmailFilter.FilterCriteria()
        if !from.isEmpty { criteria.from = from }
        if !to.isEmpty { criteria.to = to }
        if !subject.isEmpty { criteria.subject = subject }
        if !query.isEmpty { criteria.query = query }
        if hasAttachment { criteria.hasAttachment = true }

        var action = GmailFilter.FilterAction()
        var removeLabels: [String] = []
        var addLabels: [String] = []
        if shouldArchive { removeLabels.append("INBOX") }
        if shouldMarkRead { removeLabels.append("UNREAD") }
        if shouldStar { addLabels.append("STARRED") }
        if let labelId = selectedLabelId { addLabels.append(labelId) }
        if !addLabels.isEmpty { action.addLabelIds = addLabels }
        if !removeLabels.isEmpty { action.removeLabelIds = removeLabels }

        do {
            let filter = try await GmailFilterService.shared.createFilter(
                criteria: criteria, action: action, accountID: accountID
            )
            onSave(filter)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/Settings/FilterEditorView.swift
git commit -m "feat: add FilterEditorView for creating Gmail filters"
```

---

### Task 39: Gmail Filters — Add Filters Tab to SettingsView

**Files:**
- Modify: `Serif/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Add Filters tab**

Add a new tab after the "Advanced" tab (line 19):

```swift
Tab("Filters", systemImage: "line.3.horizontal.decrease.circle") {
    FiltersSettingsView(accountID: accountID)
}
```

Add `accountID` as a parameter to `SettingsView`:

```swift
struct SettingsView: View {
    let accountID: String
```

Update the frame to accommodate the new tab:

```swift
.frame(width: 500, height: 400)
```

Note: The caller of `SettingsView` is in `SerifApp.swift` at line 29: `SettingsView()`. Update it to pass the current account ID:

```swift
SettingsView(accountID: coordinator?.accountID ?? "")
```

The implementing engineer must trace the exact call site and ensure the `accountID` is available. If `SettingsView` is in a `Settings { }` scene without access to `coordinator`, consider making `accountID` default to `""` and fetching it from `AuthViewModel` or `AccountStore` within the view.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/Settings/SettingsView.swift
git commit -m "feat: add Filters tab to Settings"
```

---

### Task 40: Gmail Filters — Add "Create filter from email" to Context Menu

**Files:**
- Modify: `Serif/Views/EmailList/EmailContextMenu.swift`

- [ ] **Step 1: Add create filter menu item**

Add a callback property:

```swift
let onCreateFilter: ((Email) -> Void)?
```

Add menu item after the spam section (after line 63):

```swift
Divider()
Button { onCreateFilter?(email) } label: {
    Label("Create Filter...", systemImage: "line.3.horizontal.decrease.circle")
}
```

Note: The implementing engineer should wire `onCreateFilter` through `ListPaneView` → `EmailListView` → `EmailContextMenu` to open `FilterEditorView` pre-filled with the email's sender in the `from` field.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/EmailList/EmailContextMenu.swift
git commit -m "feat: add 'Create filter from email' to context menu"
```

---

### Task 41: Label Suggestions — Enhance Dismissal Learning

**Files:**
- Modify: `Serif/Services/LabelSuggestionService.swift`
- Modify: `Serif/Views/EmailDetail/LabelEditorView.swift`

- [ ] **Step 1: Add dismissal tracking**

In `LabelSuggestionService`, add a blocklist persisted per account:

```swift
private var dismissedSuggestions: [String: Set<String>] = [:] // accountID -> Set<"messageId:labelName">

func dismissSuggestion(labelName: String, messageId: String, accountID: String) {
    let key = "\(messageId):\(labelName)"
    dismissedSuggestions[accountID, default: []].insert(key)
    saveDismissals(accountID: accountID)
}

func isDismissed(labelName: String, messageId: String, accountID: String) -> Bool {
    let key = "\(messageId):\(labelName)"
    return dismissedSuggestions[accountID]?.contains(key) ?? false
}
```

In `LabelEditorView`, add a dismiss button (X) on each suggestion chip that calls `dismissSuggestion`.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/LabelSuggestionService.swift Serif/Views/EmailDetail/LabelEditorView.swift
git commit -m "feat: add dismissal learning to label suggestions"
```

---

## Chunk 4: Phase 4 — "Native Excellence" (Platform Polish)

### Task 42: Liquid Glass — Sidebar and Scroll Edge Effects

**Files:**
- Modify: `Serif/Views/Sidebar/SidebarView.swift`
- Modify: `Serif/Views/EmailList/ListPaneView.swift`
- Modify: `Serif/ContentView.swift`

- [ ] **Step 1: Remove custom backgrounds from SidebarView**

In `SidebarView`, the sidebar already uses `.listStyle(.sidebar)` at line 83 which gets automatic Liquid Glass treatment from `NavigationSplitView`. Verify no custom `.background()` modifiers interfere. If any exist, remove them.

- [ ] **Step 2: Add scroll edge effects to ListPaneView**

Add `.scrollEdgeEffectStyle(.automatic)` to the email list scroll view. The exact location depends on the `EmailListView` implementation — add it to the outermost `ScrollView` or `List` in `EmailListView.swift`.

- [ ] **Step 3: Add background extension to ContentView**

Add `.backgroundExtensionEffect()` to the detail pane content so it extends behind the sidebar glass:

In ContentView line 91 (the detail content), add:

```swift
.backgroundExtensionEffect()
```

Add window resize anchor to the main view:

```swift
.windowResizeAnchor(.top)
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Serif/Views/Sidebar/SidebarView.swift Serif/Views/EmailList/ListPaneView.swift Serif/ContentView.swift
git commit -m "feat: adopt Liquid Glass with scroll edge effects and background extension"
```

---

### Task 43: Liquid Glass — Toolbar Grouping

**Files:**
- Modify: `Serif/Views/EmailDetail/DetailToolbarView.swift`

- [ ] **Step 1: Group related toolbar buttons with ToolbarItemGroup**

The `DetailToolbarView` currently uses a manual `HStack`. For Liquid Glass, group related buttons using `ToolbarItemGroup` patterns. Remove custom backgrounds, borders, and dividers — let glass material handle visual separation:

Remove the manual `Divider().frame(height: 16)` elements (lines 77, 90).

Replace `.foregroundStyle(.secondary)` on buttons with standard styling — the glass background provides contrast.

Use `.buttonStyle(.borderedProminent)` for the primary Reply button if one is added to the toolbar.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Views/EmailDetail/DetailToolbarView.swift
git commit -m "feat: adopt Liquid Glass toolbar grouping in detail view"
```

---

### Task 44: App Intents — Create EmailEntity

**Files:**
- Create: `Serif/Intents/EmailEntity.swift`

- [ ] **Step 1: Create the IndexedEntity**

```swift
import AppIntents

struct EmailEntity: IndexedEntity {
    static let defaultQuery = EmailEntityQuery()
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Email"

    @Property(title: "Subject")
    var subject: String

    @Property(title: "Sender")
    var senderName: String

    @Property(title: "Date")
    var date: Date

    var id: String // Gmail message ID

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(subject)", subtitle: "\(senderName)")
    }

    init() {
        self.id = ""
        self.subject = ""
        self.senderName = ""
        self.date = Date()
    }

    init(id: String, subject: String, senderName: String, date: Date) {
        self.id = id
        self.subject = subject
        self.senderName = senderName
        self.date = date
    }
}

struct EmailEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [EmailEntity] {
        let messages = await MailCacheStore.shared.cachedMessages
        return messages
            .filter { $0.subject?.localizedCaseInsensitiveContains(string) == true ||
                      $0.from?.localizedCaseInsensitiveContains(string) == true }
            .prefix(20)
            .map { EmailEntity(id: $0.id, subject: $0.subject ?? "", senderName: $0.from ?? "", date: $0.internalDate ?? Date()) }
    }

    func entities(for identifiers: [String]) async throws -> [EmailEntity] {
        let messages = await MailCacheStore.shared.cachedMessages
        return identifiers.compactMap { id in
            guard let msg = messages.first(where: { $0.id == id }) else { return nil }
            return EmailEntity(id: msg.id, subject: msg.subject ?? "", senderName: msg.from ?? "", date: msg.internalDate ?? Date())
        }
    }

    func suggestedEntities() async throws -> [EmailEntity] {
        let messages = await MailCacheStore.shared.cachedMessages
        return messages
            .prefix(10)
            .map { EmailEntity(id: $0.id, subject: $0.subject ?? "", senderName: $0.from ?? "", date: $0.internalDate ?? Date()) }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Intents/EmailEntity.swift
git commit -m "feat: add EmailEntity as IndexedEntity for Spotlight"
```

---

### Task 45: App Intents — Create OpenEmailIntent and ComposeEmailIntent

**Files:**
- Create: `Serif/Intents/OpenEmailIntent.swift`
- Create: `Serif/Intents/ComposeEmailIntent.swift`

- [ ] **Step 1: Create OpenEmailIntent**

```swift
import AppIntents

struct OpenEmailIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Email"
    static let description: IntentDescription = "Opens a specific email in Serif"
    static let openAppWhenRun = true

    @Parameter(title: "Email")
    var email: EmailEntity

    func perform() async throws -> some IntentResult {
        // Post notification to navigate to email
        await MainActor.run {
            NotificationCenter.default.post(
                name: .openEmailFromIntent,
                object: nil,
                userInfo: ["messageId": email.id]
            )
        }
        return .result()
    }
}

extension Notification.Name {
    static let openEmailFromIntent = Notification.Name("openEmailFromIntent")
}
```

- [ ] **Step 2: Create ComposeEmailIntent**

```swift
import AppIntents

struct ComposeEmailIntent: AppIntent {
    static let title: LocalizedStringResource = "Compose Email"
    static let description: IntentDescription = "Opens a new compose window in Serif"
    static let openAppWhenRun = true

    @Parameter(title: "Recipient", default: nil)
    var recipient: String?

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .composeEmailFromIntent,
                object: nil,
                userInfo: recipient.map { ["recipient": $0] } ?? [:]
            )
        }
        return .result()
    }
}

extension Notification.Name {
    static let composeEmailFromIntent = Notification.Name("composeEmailFromIntent")
}
```

- [ ] **Step 3: Create SearchEmailIntent**

Create `Serif/Intents/SearchEmailIntent.swift`:

```swift
import AppIntents

struct SearchEmailIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Email"
    static let description: IntentDescription = "Searches emails in Serif"
    static let openAppWhenRun = true

    @Parameter(title: "Query")
    var query: String

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .searchEmailFromIntent,
                object: nil,
                userInfo: ["query": query]
            )
        }
        return .result()
    }
}

extension Notification.Name {
    static let searchEmailFromIntent = Notification.Name("searchEmailFromIntent")
}
```

- [ ] **Step 4: Create MarkAsReadIntent**

Create `Serif/Intents/MarkAsReadIntent.swift`:

```swift
import AppIntents

struct MarkAsReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Email as Read"
    static let description: IntentDescription = "Marks an email as read in Serif"
    static let openAppWhenRun = false  // Background intent — no UI needed

    @Parameter(title: "Email")
    var email: EmailEntity

    func perform() async throws -> some IntentResult {
        // Get account from the first available account
        // The implementing engineer should determine how to resolve accountID from the entity
        // For now, use a placeholder approach
        return .result()
    }
}
```

Note: The implementing engineer should wire `MarkAsReadIntent` to call `GmailMessageService.shared.markAsRead()` once the account resolution strategy is determined (likely stored in `EmailEntity`'s extended properties).

- [ ] **Step 5: Migrate SpotlightIndexer to IndexedEntity**

Modify `Serif/Services/SpotlightIndexer.swift` — replace `CSSearchableItem` usage with `IndexedEntity`:

```swift
// Replace existing CSSearchableItem indexing with:
func indexEmail(_ email: Email) {
    guard let msgId = email.gmailMessageID else { return }
    let entity = EmailEntity(
        id: msgId,
        subject: email.subject,
        senderName: email.sender.name,
        date: email.date
    )
    // IndexedEntity auto-registers with Spotlight when created
    // Existing CSSearchableItem items are replaced on first run
}
```

The implementing engineer should read `SpotlightIndexer.swift` to understand the current indexing flow and replace `CSSearchableItem`/`CSSearchableIndex` calls with `IndexedEntity` equivalents. On first run after migration, call `CSSearchableIndex.default().deleteAllSearchableItems()` to clean up legacy items.

- [ ] **Step 6: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Serif/Intents/ Serif/Services/SpotlightIndexer.swift
git commit -m "feat: add App Intents for Spotlight/Siri and migrate SpotlightIndexer"
```

---

### Task 46: Handoff — Verify and Enhance NSUserActivity

**Files:**
- Modify: `Serif/ContentView.swift:122-136`

- [ ] **Step 1: Verify existing Handoff implementation**

ContentView already has `.userActivity` and `.onContinueUserActivity` at lines 122-136. Verify:
- Activity type matches Info.plist `NSUserActivityTypes`
- `isEligibleForHandoff = true` is set (line 125 ✓)
- `isEligibleForSearch = true` is set (line 126 ✓)
- Thread ID is included in userInfo for proper navigation

Update activity type to match the spec's reverse-DNS format, and use `gmailThreadID` for cross-device compatibility:

```swift
.userActivity("com.genyus.serif.viewEmail", isActive: coordinator.selectedEmail != nil) { activity in
    guard let email = coordinator.selectedEmail else { return }
    activity.title = email.subject
    activity.isEligibleForHandoff = true
    activity.isEligibleForSearch = true
    activity.userInfo = [
        "emailID": email.id.uuidString,
        "threadID": email.gmailThreadID ?? "",
        "accountID": coordinator.accountID
    ]
}
```

Also update the `.onContinueUserActivity` handler to use the new activity type:

```swift
.onContinueUserActivity("com.genyus.serif.viewEmail") { activity in
```

- [ ] **Step 2: Add compose activity type**

Add a second `.userActivity` for compose mode:

```swift
.userActivity("com.genyus.serif.composeEmail", isActive: coordinator.isComposeActive) { activity in
    activity.title = "Composing email"
    activity.isEligibleForHandoff = true
}
```

- [ ] **Step 3: Verify Info.plist has activity types registered**

Check `Info.plist` for `NSUserActivityTypes` array containing both:
- `com.genyus.serif.viewEmail`
- `com.genyus.serif.composeEmail`

If missing, add them.

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Serif/ContentView.swift
git commit -m "feat: enhance Handoff with thread ID and compose activity"
```

---

### Task 47: Local Notifications — Create NotificationService

**Files:**
- Create: `Serif/Services/NotificationService.swift`

- [ ] **Step 1: Create notification service**

```swift
import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    private override init() { super.init() }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Register categories
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY", title: "Reply",
            textInputButtonTitle: "Send", textInputPlaceholder: "Type reply..."
        )
        let archiveAction = UNNotificationAction(identifier: "ARCHIVE", title: "Archive")
        let markReadAction = UNNotificationAction(identifier: "MARK_READ", title: "Mark Read")

        let emailCategory = UNNotificationCategory(
            identifier: "NEW_EMAIL",
            actions: [replyAction, archiveAction, markReadAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([emailCategory])

        Task {
            let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted != true {
                print("[NotificationService] Permission not granted")
            }
        }
    }

    func notifyNewEmail(
        messageId: String,
        threadId: String,
        senderName: String,
        subject: String,
        snippet: String,
        accountID: String
    ) {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }

        let content = UNMutableNotificationContent()
        content.title = senderName
        content.subtitle = subject
        content.body = String(snippet.prefix(100))
        content.categoryIdentifier = "NEW_EMAIL"
        content.threadIdentifier = threadId // Apple Intelligence auto-groups by thread
        content.userInfo = [
            "messageId": messageId,
            "threadId": threadId,
            "accountID": accountID
        ]

        let request = UNNotificationRequest(
            identifier: messageId,
            content: content,
            trigger: nil // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let messageId = userInfo["messageId"] as? String,
              let accountID = userInfo["accountID"] as? String else { return }

        switch response.actionIdentifier {
        case "ARCHIVE":
            // Route through MainActor since GmailMessageService is @MainActor
            await MainActor.run {
                Task { try? await GmailMessageService.shared.archiveMessage(id: messageId, accountID: accountID) }
            }
        case "MARK_READ":
            await MainActor.run {
                Task { try? await GmailMessageService.shared.markAsRead(id: messageId, accountID: accountID) }
            }
        case "REPLY":
            if let textResponse = response as? UNTextInputNotificationResponse {
                // Quick reply from notification
                let text = textResponse.userText
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .quickReplyFromNotification,
                        object: nil,
                        userInfo: ["messageId": messageId, "text": text, "accountID": accountID]
                    )
                }
            }
        default:
            // Default tap — open the email
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .openEmailFromIntent,
                    object: nil,
                    userInfo: ["messageId": messageId]
                )
            }
        }
    }
}

extension Notification.Name {
    static let quickReplyFromNotification = Notification.Name("quickReplyFromNotification")
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/Services/NotificationService.swift
git commit -m "feat: add NotificationService with actionable local notifications"
```

---

### Task 48: Local Notifications — Wire to HistorySyncService and App Startup

**Files:**
- Modify: `Serif/Services/HistorySyncService.swift`
- Modify: `Serif/SerifApp.swift`
- Modify: `Serif/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Trigger notifications from HistorySyncService**

In `HistorySyncService`, when `messagesAdded` events are detected during sync, call `NotificationService.shared.notifyNewEmail()` for each new inbox message. Rate limit to max 5 per sync cycle.

The implementing engineer should find the history sync processing code and add notification calls after new messages are detected. Pattern:

```swift
// After detecting new messages in sync
let newMessages = messagesAdded.prefix(5)
for msg in newMessages {
    NotificationService.shared.notifyNewEmail(
        messageId: msg.id,
        threadId: msg.threadId ?? "",
        senderName: msg.senderName,
        subject: msg.subject,
        snippet: msg.snippet ?? "",
        accountID: accountID
    )
}
```

- [ ] **Step 2: Register notification categories on app launch**

In `SerifApp.swift`, add to the app init or `.onAppear`:

```swift
NotificationService.shared.setup()
```

- [ ] **Step 3: Add notification toggle to SettingsView**

Add to the General tab in `SettingsView`:

```swift
@AppStorage("showNotifications") private var showNotifications = true

// In the Behavior section:
Toggle("Show notifications for new emails", isOn: $showNotifications)
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Serif/Services/HistorySyncService.swift Serif/SerifApp.swift Serif/Views/Settings/SettingsView.swift
git commit -m "feat: wire notifications to history sync and add settings toggle"
```

---

### Task 49: Accessibility — Email Row Improvements

**Files:**
- Modify: `Serif/Views/EmailList/EmailRowView.swift`
- Modify: `Serif/Views/EmailList/EmailListView.swift`

- [ ] **Step 1: Add accessibility modifiers to EmailRowView**

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel("\(email.sender.name), \(email.subject), \(email.preview), \(email.date.formatted())")
.accessibilityHint(email.isStarred ? "Starred" : "Not starred")
.accessibilityAction(named: "Archive") { onArchive?(email) }
.accessibilityAction(named: "Star") { onToggleStar?(email) }
.accessibilityAction(named: "Mark as Read") { onMarkUnread?(email) }
```

- [ ] **Step 2: Add VoiceOver rotors to EmailListView**

```swift
.accessibilityRotor("Unread Emails") {
    ForEach(emails.filter { !$0.isRead }) { email in
        AccessibilityRotorEntry(email.subject, id: email.id)
    }
}
.accessibilityRotor("Starred") {
    ForEach(emails.filter { $0.isStarred }) { email in
        AccessibilityRotorEntry(email.subject, id: email.id)
    }
}
.accessibilityRotor("Has Attachments") {
    ForEach(emails.filter { $0.hasAttachments }) { email in
        AccessibilityRotorEntry(email.subject, id: email.id)
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Serif/Views/EmailList/EmailRowView.swift Serif/Views/EmailList/EmailListView.swift
git commit -m "feat: add VoiceOver rotors and accessibility actions to email list"
```

---

### Task 49a: Accessibility — Sidebar and Detail View

**Files:**
- Modify: `Serif/Views/Sidebar/SidebarView.swift`
- Modify: `Serif/Views/EmailDetail/EmailDetailView.swift`

- [ ] **Step 1: Add folder rotor to SidebarView**

```swift
.accessibilityRotor("Folders") {
    ForEach(Folder.allCases.filter { $0 != .labels }) { folder in
        AccessibilityRotorEntry(folder.rawValue, id: folder.id)
    }
}
```

- [ ] **Step 2: Add accessibility to EmailDetailView**

Add descriptive labels to the detail view components:

```swift
// On the email body container:
.accessibilityLabel("Email from \(email.sender.name): \(email.subject)")

// On attachment chips:
.accessibilityLabel("Attachment: \(attachment.name), \(attachment.size)")
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Serif/Views/Sidebar/SidebarView.swift Serif/Views/EmailDetail/EmailDetailView.swift
git commit -m "feat: add accessibility rotors and labels to sidebar and detail view"
```

---

### Task 50: Drag and Drop — Email Rows and Sidebar

**Files:**
- Create: `Serif/Models/EmailDragItem.swift`
- Modify: `Serif/Views/EmailList/EmailRowView.swift`
- Modify: `Serif/Views/Sidebar/SidebarView.swift`

- [ ] **Step 1: Create EmailDragItem**

```swift
import Foundation
import UniformTypeIdentifiers

struct EmailDragItem: Codable, Transferable {
    let messageIds: [String]
    let accountID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .emailDragItem)
    }
}

extension UTType {
    static let emailDragItem = UTType(exportedAs: "com.genyus.serif.email-drag-item")
}
```

Note: Register `com.genyus.serif.email-drag-item` UTType in Info.plist under `UTExportedTypeDeclarations`.

- [ ] **Step 2: Add `.draggable()` to EmailRowView**

The parent view must pass the current `accountID` into `EmailRowView`. Add an `accountID: String` parameter to `EmailRowView` and thread it from `EmailListView`.

For single-selection:
```swift
.draggable(EmailDragItem(
    messageIds: [email.gmailMessageID ?? ""],
    accountID: accountID
))
```

For multi-selection (when `selectedEmailIDs` contains multiple items and this row is selected):
```swift
.draggable(EmailDragItem(
    messageIds: selectedEmailIDs.compactMap { id in
        emails.first(where: { $0.id.uuidString == id })?.gmailMessageID
    },
    accountID: accountID
))
```

Use the multi-select variant when `selectedEmailIDs.count > 1 && selectedEmailIDs.contains(email.id.uuidString)`, otherwise use single.

- [ ] **Step 3: Add `.dropDestination()` to SidebarView label rows**

In `labelButton(label:)` (line 159), add:

```swift
.dropDestination(for: EmailDragItem.self) { items, _ in
    for item in items {
        for msgId in item.messageIds {
            Task {
                try? await GmailMessageService.shared.modifyLabels(
                    id: msgId, add: [label.id], remove: [], accountID: item.accountID
                )
            }
        }
    }
    return true
}
```

Add drop destinations to folder buttons for archive/trash:

```swift
.dropDestination(for: EmailDragItem.self) { items, _ in
    for item in items {
        for msgId in item.messageIds {
            Task {
                switch folder {
                case .trash:
                    try? await GmailMessageService.shared.trashMessage(id: msgId, accountID: item.accountID)
                case .archive:
                    try? await GmailMessageService.shared.archiveMessage(id: msgId, accountID: item.accountID)
                case .spam:
                    try? await GmailMessageService.shared.spamMessage(id: msgId, accountID: item.accountID)
                default: break
                }
            }
        }
    }
    return true
}
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Serif/Models/EmailDragItem.swift Serif/Views/EmailList/EmailRowView.swift Serif/Views/Sidebar/SidebarView.swift
git commit -m "feat: add drag and drop for emails to labels and folders"
```

---

### Task 51: Undo Send — Route Send Through UndoActionManager

**Files:**
- Modify: `Serif/ViewModels/ComposeViewModel.swift`
- Modify: `Serif/Views/Compose/ComposeView.swift`

- [ ] **Step 1: Modify send() to use undo countdown**

Replace the `send()` method (find `func send() async`) to route through `UndoActionManager`:

```swift
/// State for undo-send countdown
var isAwaitingUndoSend = false

func send() async {
    error = nil
    isAwaitingUndoSend = true
    isSending = true

    UndoActionManager.shared.schedule(
        label: "Sending...",
        onConfirm: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAwaitingUndoSend = false
                await self.executeSend()
            }
        },
        onUndo: {
            Task { @MainActor [weak self] in
                self?.isAwaitingUndoSend = false
                self?.isSending = false
            }
        }
    )
}

private func executeSend() async {
    defer { isSending = false }
    do {
        _ = try await GmailSendService.shared.send(
            from: fromAddress,
            to: splitAddresses(to),
            cc: splitAddresses(cc),
            bcc: splitAddresses(bcc),
            subject: subject,
            body: body,
            isHTML: isHTML,
            threadID: threadID,
            referencesHeader: replyToMessageID,
            inlineImages: inlineImages,
            attachments: attachmentURLs.isEmpty ? nil : attachmentURLs,
            accountID: accountID
        )
        if let draftID = gmailDraftID {
            try? await GmailSendService.shared.deleteDraft(draftID: draftID, accountID: accountID)
        }
        isSent = true
    } catch {
        self.error = error.localizedDescription
    }
}
```

- [ ] **Step 2: Add countdown UI to ComposeView**

In `ComposeView`, when `isSending` is true and `UndoActionManager.shared.currentAction` exists, show a banner:

```swift
if composeVM.isSending, let action = UndoActionManager.shared.currentAction {
    HStack {
        Text("Sending in \(Int(UndoActionManager.shared.timeRemaining))s...")
            .font(.subheadline)
        Spacer()
        Button("Undo") {
            UndoActionManager.shared.undo()
        }
        .buttonStyle(.bordered)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.yellow.opacity(0.1))
}
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Serif/ViewModels/ComposeViewModel.swift Serif/Views/Compose/ComposeView.swift
git commit -m "feat: add undo-send with countdown timer"
```

---

### Task 52: Start SnoozeMonitor on App Launch

**Files:**
- Modify: `Serif/SerifApp.swift`

- [ ] **Step 1: Start background monitors on app launch**

Add to the app init or the main `WindowGroup` `.onAppear`:

```swift
// Start background monitors
SnoozeMonitor.shared.start()

// Load snooze/scheduled data for all accounts
for account in authViewModel.accounts {
    SnoozeStore.shared.load(accountID: account.id)
    ScheduledSendStore.shared.load(accountID: account.id)
    OfflineActionQueue.shared.load(accountID: account.id)
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Serif -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Serif/SerifApp.swift
git commit -m "feat: start snooze/scheduled monitors and load stores on launch"
```

---
