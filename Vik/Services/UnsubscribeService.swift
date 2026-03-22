import Foundation
import AppKit

// MARK: - Model

struct UnsubscribedMessageID: Codable, Identifiable, Sendable {
    let id: String          // Gmail message ID
    let accountID: String
}

/// Handles all unsubscribe interactions: RFC 8058 one-click POST, browser URL, mailto, and body link scanning.
@MainActor
final class UnsubscribeService {
    static let shared = UnsubscribeService()
    private init() {}

    private let store = PerAccountFileStore<UnsubscribedMessageID>(
        fileURL: { accountID in
            AppPaths.appSupportDirectory
                .appendingPathComponent("mail-data/\(accountID)/unsubscribed.json")
        }
    )

    // MARK: - Persisted state

    func load(accountID: String) async {
        await store.loadFiltered(by: accountID, keyPath: \.accountID)
    }

    func isUnsubscribed(messageID: String, accountID: String) -> Bool {
        store.itemsByAccount[accountID]?.contains(where: { $0.id == messageID }) ?? false
    }

    private func markUnsubscribed(messageID: String, accountID: String) {
        guard !isUnsubscribed(messageID: messageID, accountID: accountID) else { return }
        store.append(UnsubscribedMessageID(id: messageID, accountID: accountID), accountID: accountID)
    }

    func clearAccount(_ accountID: String) {
        store.deleteAccount(accountID)
    }

    // MARK: - Perform unsubscribe

    /// Returns `true` when we can confirm the unsubscribe succeeded (one-click with 2xx).
    @discardableResult
    func unsubscribe(url: URL, oneClick: Bool, messageID: String? = nil, accountID: String = "") async -> Bool {
        if oneClick && (url.scheme == "https" || url.scheme == "http") {
            let success = await performOneClickPost(url: url)
            if success, let messageID { markUnsubscribed(messageID: messageID, accountID: accountID) }
            return success
        } else if url.scheme == "https" || url.scheme == "http" || url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
            return false
        } else {
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

    private static let bodyUnsubscribeRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"href=["'](https?://[^"'\s>]+)["'][^>]*>(?:[^<]{0,300})(?:unsubscribe|opt.out|désabonner|se désinscrire|remove me)"#,
            options: .caseInsensitive
        )
    }()

    /// Scans an HTML (or plain-text) email body for the first unsubscribe link.
    /// Returns nil if no link is found.
    static func extractBodyUnsubscribeURL(from html: String) -> URL? {
        let range = NSRange(html.startIndex..., in: html)
        guard let match = bodyUnsubscribeRegex.firstMatch(in: html, options: [], range: range),
              let urlRange = Range(match.range(at: 1), in: html)
        else { return nil }

        return URL(string: String(html[urlRange]))
    }
}
