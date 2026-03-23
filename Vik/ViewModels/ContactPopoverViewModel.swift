import SwiftUI
import AppKit
private import GRDB
private import os

@Observable @MainActor
final class ContactPopoverViewModel: Identifiable {
    let id = UUID()
    let contact: Contact
    private let message: GmailMessage?
    private let accountID: String
    private let onComposeTo: @MainActor (String) -> Void
    private let onSearchSender: @MainActor (String) -> Void

    var isKnownContact = false
    var organization: String?
    var phoneNumber: String?
    var location: String?
    var isEnriching = false
    var resourceName: String?

    // MARK: - Header-derived info (unknown senders)

    var sentByDomain: String? { message?.fromDomain }
    var mailedBy: String? { message?.mailedBy }
    var signedBy: String? { message?.signedBy }
    var encryptionInfo: String? { message?.encryptionInfo }
    var isSuspiciousSender: Bool { message?.isSuspiciousSender ?? false }

    // MARK: - Enrichment Cache

    private static var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 300 // 5 minutes
    private static let maxCacheSize = 200

    private struct CacheEntry {
        let details: PersonDetails
        let timestamp: Date
    }

    static func cachedPersonDetails(forEmail email: String, accountID: String = "") -> PersonDetails? {
        let key = "\(accountID):\(email.lowercased())"
        guard let entry = cache[key],
              Date().timeIntervalSince(entry.timestamp) < cacheTTL else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.details
    }

    static func cachePersonDetails(_ details: PersonDetails, forEmail email: String, accountID: String = "") {
        let key = "\(accountID):\(email.lowercased())"
        if cache.count >= maxCacheSize {
            let now = Date()
            cache = cache.filter { now.timeIntervalSince($0.value.timestamp) < cacheTTL }
            if cache.count >= maxCacheSize {
                let toRemove = cache.sorted { $0.value.timestamp < $1.value.timestamp }
                    .prefix(cache.count - maxCacheSize + 1)
                    .map(\.key)
                for k in toRemove { cache.removeValue(forKey: k) }
            }
        }
        cache[key] = CacheEntry(details: details, timestamp: Date())
    }

    // MARK: - Init

    init(
        contact: Contact,
        message: GmailMessage?,
        accountID: String,
        composeTo: @escaping @MainActor (String) -> Void,
        searchSender: @escaping @MainActor (String) -> Void
    ) {
        self.contact = contact
        self.message = message
        self.accountID = accountID
        self.onComposeTo = composeTo
        self.onSearchSender = searchSender
    }

    // MARK: - Load

    func load() async {
        guard let db = try? await MailDatabase.shared(for: accountID) else { return }
        let email = contact.email.lowercased()

        let record = try? await db.dbPool.read { db in
            try ContactRecord.filter(Column("email").collating(.nocase) == email).fetchOne(db)
        }

        if let record {
            isKnownContact = true
            resourceName = record.resourceName
            await enrich(email: email)
        }
    }

    private func enrich(email: String) async {
        if let cached = Self.cachedPersonDetails(forEmail: email, accountID: accountID) {
            applyDetails(cached)
            return
        }

        guard let resourceName else { return }
        isEnriching = true

        let details = await PeopleAPIService.shared.fetchPersonDetails(
            resourceName: resourceName,
            accountID: accountID
        )

        isEnriching = false

        if let details {
            Self.cachePersonDetails(details, forEmail: email, accountID: accountID)
            withAnimation(NSWorkspace.reduceMotion ? nil : VikAnimation.springSnappy) {
                applyDetails(details)
            }
        }
    }

    private func applyDetails(_ details: PersonDetails) {
        organization = details.organization
        phoneNumber = details.phoneNumber
        location = details.location
    }

    // MARK: - Actions

    func copyEmail() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contact.email, forType: .string)
    }

    func composeEmail() {
        onComposeTo(contact.email)
    }

    func searchEmails() {
        onSearchSender(contact.email)
    }

    func openContact() {
        guard let resourceName else { return }
        let urlStr = "https://contacts.google.com/person/\(resourceName)"
        guard let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }

    func addToContacts() {
        var components = URLComponents(string: "https://contacts.google.com/new")!
        components.queryItems = [
            URLQueryItem(name: "email", value: contact.email),
            URLQueryItem(name: "name", value: contact.name),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}
