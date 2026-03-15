import Foundation
import GRDB
private import os

/// Fetches contacts and photos from the Google People API.
@MainActor
final class PeopleAPIService {
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.serif", category: "PeopleAPI")
    static let shared = PeopleAPIService()
    private init() {}

    /// Loads contacts: uses local cache if available, otherwise fetches from network.
    /// The caller must supply the `BackgroundSyncer` for the account so contact
    /// writes are serialized through the same actor instance used by the sync engine.
    func loadContactPhotos(accountID: String, syncer: BackgroundSyncer) async {
        let local: [StoredContact] = (try? await MailDatabase.shared(for: accountID).dbPool.read { db in
            try MailDatabaseQueries.allContacts(in: db).map {
                StoredContact(name: $0.name ?? $0.email, email: $0.email, photoURL: $0.photoUrl)
            }
        }) ?? []
        if !local.isEmpty {
            Self.logger.debug("Using \(local.count, privacy: .public) cached contacts for \(accountID, privacy: .private)")
            for contact in local {
                if let url = contact.photoURL {
                    ContactPhotoCache.shared.set(url, for: contact.email)
                }
            }
            return
        }
        await fetchAndStoreContacts(accountID: accountID, syncer: syncer)
    }

    /// Forces a network refresh of contacts, replacing the local cache.
    /// The caller must supply the `BackgroundSyncer` for the account so contact
    /// writes are serialized through the same actor instance used by the sync engine.
    func refreshContacts(accountID: String, syncer: BackgroundSyncer) async {
        await fetchAndStoreContacts(accountID: accountID, syncer: syncer)
        if UserDefaults.standard.bool(forKey: "syncDirectoryContacts") {
            await fetchDirectoryPeople(accountID: accountID, syncer: syncer)
        }
    }

    /// Extracts StoredContacts from a PersonResource array, updating the photo cache.
    private func parseContacts(from persons: [PersonResource]) -> [StoredContact] {
        var contacts: [StoredContact] = []
        for person in persons {
            let displayName = person.names?.first?.displayName ?? ""
            let photoURL = person.photos?.first(where: { $0.default != true })?.url
            for addr in person.emailAddresses ?? [] {
                guard let email = addr.value, !email.isEmpty else { continue }
                let lowered = email.lowercased()
                if let url = photoURL {
                    ContactPhotoCache.shared.set(url, for: lowered)
                }
                contacts.append(StoredContact(name: displayName, email: lowered, photoURL: photoURL))
            }
        }
        return contacts
    }

    /// Merges `incoming` contacts into `existing`, replacing by email match.
    /// Runs off MainActor to avoid blocking the UI with O(n) dictionary lookups.
    nonisolated
    private func mergeContacts(existing: [StoredContact], incoming: [StoredContact]) -> [StoredContact] {
        var byEmail: [String: Int] = [:]
        var result = existing
        for (index, contact) in result.enumerated() {
            byEmail[contact.email] = index
        }
        for contact in incoming {
            if let idx = byEmail[contact.email] {
                result[idx] = contact
            } else {
                byEmail[contact.email] = result.count
                result.append(contact)
            }
        }
        return result
    }

    /// Deduplicates contacts by email and prepares upsert tuples, off MainActor.
    nonisolated
    private func deduplicateContacts(_ contacts: [StoredContact]) -> [StoredContact] {
        var seen = Set<String>()
        return contacts.filter { seen.insert($0.email).inserted }
    }

    /// Fetches contacts from People API and persists them.
    /// Uses sync tokens for incremental updates when available.
    /// The caller supplies `syncer` so writes are serialized through the same actor used by the sync engine.
    private func fetchAndStoreContacts(accountID: String, syncer: BackgroundSyncer) async {
        var allContacts: [StoredContact] = []
        var deletedEmails = Set<String>()

        let mailDB = try? MailDatabase.shared(for: accountID)

        // 1. Fetch "My Contacts" via connections
        do {
            let syncToken: String? = try? await mailDB?.dbPool.read { db in
                try MailDatabaseQueries.syncState(in: db)?.contactsSyncToken
            }
            var newSyncToken: String?
            var needsFullFetch = syncToken == nil

            if let syncToken, !needsFullFetch {
                allContacts = (try? await mailDB?.dbPool.read { db in
                    try MailDatabaseQueries.allContacts(in: db).map {
                        StoredContact(name: $0.name ?? $0.email, email: $0.email, photoURL: $0.photoUrl)
                    }
                }) ?? []
                do {
                    var incPageToken: String? = nil
                    repeat {
                        let encodedSyncToken = syncToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? syncToken
                        var urlStr = "https://people.googleapis.com/v1/people/me/connections"
                            + "?personFields=metadata,names,emailAddresses,photos&syncToken=\(encodedSyncToken)"
                            + "&pageSize=1000"
                        if let pt = incPageToken { urlStr += "&pageToken=\(pt)" }
                        let response: PeopleConnectionsResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)
                        // Remove deleted contacts
                        let pageDeletedEmails = Set(
                            (response.connections ?? [])
                                .filter { $0.metadata?.deleted == true }
                                .flatMap { $0.emailAddresses?.compactMap { $0.value?.lowercased() } ?? [] }
                        )
                        allContacts.removeAll { pageDeletedEmails.contains($0.email) }
                        deletedEmails.formUnion(pageDeletedEmails)
                        for email in pageDeletedEmails {
                            ContactPhotoCache.shared.remove(email)
                        }

                        // Merge updated/new contacts (skip deleted ones)
                        let nonDeleted = (response.connections ?? []).filter { $0.metadata?.deleted != true }
                        let parsed = parseContacts(from: nonDeleted)
                        allContacts = mergeContacts(existing: allContacts, incoming: parsed)
                        incPageToken = response.nextPageToken
                        newSyncToken = response.nextSyncToken ?? newSyncToken
                    } while incPageToken != nil
                    Self.logger.info("Incremental sync completed")
                } catch {
                    let isGone = if case GmailAPIError.httpError(410, _) = error { true } else { false }
                    if isGone {
                        Self.logger.warning("Sync token expired, performing full re-fetch")
                        try? await mailDB?.dbPool.write { db in
                            try MailDatabaseQueries.updateSyncState({ $0.contactsSyncToken = nil }, in: db)
                        }
                        allContacts = []
                        needsFullFetch = true
                    } else {
                        throw error
                    }
                }
            }

            // Full fetch if no sync token or token expired
            if needsFullFetch {
                allContacts = []
                var pageToken: String? = nil
                repeat {
                    var urlStr = "https://people.googleapis.com/v1/people/me/connections"
                        + "?personFields=metadata,names,emailAddresses,photos&pageSize=1000"
                        + "&requestSyncToken=true"
                    if let pt = pageToken { urlStr += "&pageToken=\(pt)" }
                    let response: PeopleConnectionsResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)
                    allContacts.append(contentsOf: parseContacts(from: response.connections ?? []))
                    pageToken = response.nextPageToken
                    newSyncToken = response.nextSyncToken ?? newSyncToken
                } while pageToken != nil
                Self.logger.info("Full fetch: loaded \(allContacts.count, privacy: .public) contacts from Connections")
            }

            if let newSyncToken {
                try? await mailDB?.dbPool.write { db in
                    try MailDatabaseQueries.updateSyncState({ $0.contactsSyncToken = newSyncToken }, in: db)
                }
            }
        } catch {
            Self.logger.error("Connections fetch error: \(error, privacy: .public)")
        }

        // 2. Fetch "Other Contacts" (auto-created from email interactions)
        // Note: readMask omits "photos" — Other Contacts don't support photo fields.
        do {
            let otherSyncToken: String? = try? await mailDB?.dbPool.read { db in
                try MailDatabaseQueries.syncState(in: db)?.otherContactsSyncToken
            }
            var newOtherSyncToken: String?
            var needsFullOtherFetch = otherSyncToken == nil

            if let otherSyncToken, !needsFullOtherFetch {
                // Incremental sync for Other Contacts
                do {
                    var incPageToken: String? = nil
                    repeat {
                        let encodedToken = otherSyncToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? otherSyncToken
                        var urlStr = "https://people.googleapis.com/v1/otherContacts"
                            + "?readMask=metadata,names,emailAddresses&syncToken=\(encodedToken)"
                            + "&pageSize=1000"
                        if let pt = incPageToken { urlStr += "&pageToken=\(pt)" }
                        let response: OtherContactsResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)

                        // Handle deletions
                        let otherDeletedEmails = Set(
                            (response.otherContacts ?? [])
                                .filter { $0.metadata?.deleted == true }
                                .flatMap { $0.emailAddresses?.compactMap { $0.value?.lowercased() } ?? [] }
                        )
                        allContacts.removeAll { otherDeletedEmails.contains($0.email) }
                        deletedEmails.formUnion(otherDeletedEmails)

                        // Merge non-deleted
                        let nonDeleted = (response.otherContacts ?? []).filter { $0.metadata?.deleted != true }
                        let parsed = parseContacts(from: nonDeleted)
                        allContacts = mergeContacts(existing: allContacts, incoming: parsed)
                        incPageToken = response.nextPageToken
                        newOtherSyncToken = response.nextSyncToken ?? newOtherSyncToken
                    } while incPageToken != nil
                    Self.logger.info("Other Contacts incremental sync completed")
                } catch {
                    let isGone = if case GmailAPIError.httpError(410, _) = error { true } else { false }
                    if isGone {
                        Self.logger.warning("Other Contacts sync token expired, performing full re-fetch")
                        try? await mailDB?.dbPool.write { db in
                            try MailDatabaseQueries.updateSyncState({ $0.otherContactsSyncToken = nil }, in: db)
                        }
                        needsFullOtherFetch = true
                    } else {
                        throw error
                    }
                }
            }

            if needsFullOtherFetch {
                var pageToken: String? = nil
                repeat {
                    var urlStr = "https://people.googleapis.com/v1/otherContacts"
                        + "?readMask=metadata,names,emailAddresses&pageSize=1000"
                        + "&requestSyncToken=true"
                    if let pt = pageToken { urlStr += "&pageToken=\(pt)" }
                    let response: OtherContactsResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)
                    let beforeCount = allContacts.count
                    allContacts.append(contentsOf: parseContacts(from: response.otherContacts ?? []))
                    Self.logger.debug("Loaded \(allContacts.count - beforeCount, privacy: .public) from Other Contacts page")
                    pageToken = response.nextPageToken
                    newOtherSyncToken = response.nextSyncToken ?? newOtherSyncToken
                } while pageToken != nil
            }

            if let newOtherSyncToken {
                try? await mailDB?.dbPool.write { db in
                    try MailDatabaseQueries.updateSyncState({ $0.otherContactsSyncToken = newOtherSyncToken }, in: db)
                }
            }
        } catch {
            Self.logger.error("Other Contacts fetch error: \(error, privacy: .public)")
        }

        // Deduplicate by email and persist to GRDB via the caller-supplied syncer.
        let unique = deduplicateContacts(allContacts)
        // Delete contacts that were removed during incremental sync
        if !deletedEmails.isEmpty {
            try? await syncer.deleteContacts(emails: Array(deletedEmails))
        }
        let tuples = unique.map { (email: $0.email, name: Optional($0.name), photoUrl: $0.photoURL, source: "people_api", resourceName: nil as String?) }
        try? await syncer.upsertContacts(tuples)
        Self.logger.info("Total unique contacts stored: \(unique.count, privacy: .public)")
    }

    /// Fetches Google Workspace directory contacts (domain profiles + contacts).
    /// Gracefully skips if the directory.readonly scope isn't granted (403).
    /// The caller supplies `syncer` so writes are serialized through the same actor used by the sync engine.
    private func fetchDirectoryPeople(accountID: String, syncer: BackgroundSyncer) async {
        let mailDB = try? MailDatabase.shared(for: accountID)

        do {
            let dirSyncToken: String? = try? await mailDB?.dbPool.read { db in
                try MailDatabaseQueries.syncState(in: db)?.directorySyncToken
            }
            var newDirSyncToken: String?
            var directoryContacts: [StoredContact] = []
            var needsFullDirFetch = dirSyncToken == nil

            if let dirSyncToken {
                // Incremental sync
                do {
                    var incPageToken: String? = nil
                    repeat {
                        let encodedToken = dirSyncToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dirSyncToken
                        var urlStr = "https://people.googleapis.com/v1/people:listDirectoryPeople"
                            + "?sources=DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"
                            + "&sources=DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"
                            + "&readMask=metadata,names,emailAddresses,photos"
                            + "&syncToken=\(encodedToken)"
                            + "&pageSize=1000"
                        if let pt = incPageToken { urlStr += "&pageToken=\(pt)" }
                        let response: DirectoryPeopleResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)
                        directoryContacts.append(contentsOf: parseContacts(from: response.people ?? []))
                        incPageToken = response.nextPageToken
                        newDirSyncToken = response.nextSyncToken ?? newDirSyncToken
                    } while incPageToken != nil
                } catch {
                    let isGone = if case GmailAPIError.httpError(410, _) = error { true } else { false }
                    if isGone {
                        try? await mailDB?.dbPool.write { db in
                            try MailDatabaseQueries.updateSyncState({ $0.directorySyncToken = nil }, in: db)
                        }
                        needsFullDirFetch = true
                    } else {
                        throw error
                    }
                }
            }

            if needsFullDirFetch {
                directoryContacts = []
                var pageToken: String? = nil
                repeat {
                    var urlStr = "https://people.googleapis.com/v1/people:listDirectoryPeople"
                        + "?sources=DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"
                        + "&sources=DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"
                        + "&readMask=metadata,names,emailAddresses,photos"
                        + "&requestSyncToken=true&pageSize=1000"
                    if let pt = pageToken { urlStr += "&pageToken=\(pt)" }
                    let response: DirectoryPeopleResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)
                    directoryContacts.append(contentsOf: parseContacts(from: response.people ?? []))
                    pageToken = response.nextPageToken
                    newDirSyncToken = response.nextSyncToken ?? newDirSyncToken
                } while pageToken != nil
            }

            if let newDirSyncToken {
                try? await mailDB?.dbPool.write { db in
                    try MailDatabaseQueries.updateSyncState({ $0.directorySyncToken = newDirSyncToken }, in: db)
                }
            }

            // Upsert directory contacts via the caller-supplied syncer.
            if !directoryContacts.isEmpty {
                let tuples = directoryContacts.map {
                    (email: $0.email, name: Optional($0.name), photoUrl: $0.photoURL, source: "directory", resourceName: nil as String?)
                }
                try? await syncer.upsertContacts(tuples)
            }

        } catch {
            // 403 = scope not granted — skip silently
            if case GmailAPIError.httpError(403, _) = error {
                Self.logger.info("Directory contacts skipped — scope not granted")
            } else {
                Self.logger.error("Directory contacts error: \(error, privacy: .public)")
            }
        }
    }
}

// MARK: - People API response models

struct PeopleConnectionsResponse: Decodable {
    let connections: [PersonResource]?
    let nextPageToken: String?
    let nextSyncToken: String?
}

struct OtherContactsResponse: Decodable {
    let otherContacts: [PersonResource]?
    let nextPageToken: String?
    let nextSyncToken: String?
}

struct DirectoryPeopleResponse: Decodable {
    let people: [PersonResource]?
    let nextPageToken: String?
    let nextSyncToken: String?
}

struct PersonMetadata: Decodable {
    let deleted: Bool?
}

struct PersonResource: Decodable {
    let metadata: PersonMetadata?
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
