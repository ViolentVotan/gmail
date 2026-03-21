import Foundation
import AppKit

/// Handles all unsubscribe interactions: RFC 8058 one-click POST, browser URL, mailto, and body link scanning.
@MainActor
final class UnsubscribeService {
    static let shared = UnsubscribeService()
    private init() {}

    nonisolated private func doneKey(for accountID: String) -> String {
        "unsubscribedMessageIDs.\(accountID)"
    }

    // MARK: - In-memory cache

    /// Keyed by accountID → Set of unsubscribed message IDs.
    /// Populated lazily on first access per account; invalidated on clearAccount.
    private var cachedSets: [String: Set<String>] = [:]

    private func cachedSet(for accountID: String) -> Set<String> {
        if let existing = cachedSets[accountID] { return existing }
        let arr = UserDefaults.standard.stringArray(forKey: doneKey(for: accountID)) ?? []
        let set = Set(arr)
        cachedSets[accountID] = set
        return set
    }

    // MARK: - Persisted state

    func isUnsubscribed(messageID: String, accountID: String) -> Bool {
        cachedSet(for: accountID).contains(messageID)
    }

    private func markUnsubscribed(messageID: String, accountID: String) {
        guard !cachedSet(for: accountID).contains(messageID) else { return }
        cachedSets[accountID, default: []].insert(messageID)
        let arr = Array(cachedSets[accountID]!)
        UserDefaults.standard.set(arr, forKey: doneKey(for: accountID))
    }

    func clearAccount(_ accountID: String) {
        cachedSets.removeValue(forKey: accountID)
        UserDefaults.standard.removeObject(forKey: doneKey(for: accountID))
    }

    // MARK: - Perform unsubscribe

    /// Returns `true` when we can confirm the unsubscribe succeeded (one-click with 2xx).
    @discardableResult
    func unsubscribe(url: URL, oneClick: Bool, messageID: String? = nil, accountID: String = "") async -> Bool {
        if oneClick && (url.scheme == "https" || url.scheme == "http") {
            let success = await performOneClickPost(url: url)
            if success, let messageID { markUnsubscribed(messageID: messageID, accountID: accountID) }
            return success
        } else {
            NSWorkspace.shared.open(url)
            return false
        }
    }

    /// RFC 8058: POST with body "List-Unsubscribe=One-Click"
    @concurrent private func performOneClickPost(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "List-Unsubscribe=One-Click".data(using: .utf8)
        guard let (_, response) = try? await NetworkConfig.externalSession.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    // MARK: - Body link scanning

    /// Scans an HTML (or plain-text) email body for the first unsubscribe link.
    /// Returns nil if no link is found.
    static func extractBodyUnsubscribeURL(from html: String) -> URL? {
        // Pattern: href="https://..." within an <a> tag whose visible text contains an unsubscribe keyword
        // We match the href value, then verify the nearby text contains the keyword.
        guard let regex = try? NSRegularExpression(
            pattern: #"href=["'](https?://[^"'\s>]+)["'][^>]*>(?:[^<]{0,300})(?:unsubscribe|opt.out|désabonner|se désinscrire|remove me)"#,
            options: .caseInsensitive
        ) else { return nil }

        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let urlRange = Range(match.range(at: 1), in: html)
        else { return nil }

        return URL(string: String(html[urlRange]))
    }
}
