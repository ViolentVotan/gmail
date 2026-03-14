import Foundation
import GRDB

/// Fetches contacts and photos from the Google People API.
@MainActor
final class PeopleAPIService {
    static let shared = PeopleAPIService()
    private init() {}

    /// Loads contacts: uses local cache if available, otherwise fetches from network.
    func loadContactPhotos(accountID: String) async {
        let local: [StoredContact] = (try? await MailDatabase.shared(for: accountID).dbPool.read { db in
            try MailDatabaseQueries.allContacts(in: db).map {
                StoredContact(name: $0.name ?? $0.email, email: $0.email, photoURL: $0.photoUrl)
            }
        }) ?? []
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
        if UserDefaults.standard.bool(forKey: "syncDirectoryContacts") {
            await fetchDirectoryPeople(accountID: accountID)
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

    /// Fetches contacts from People API and persists them.
    /// Uses sync tokens for incremental updates when available.
    private func fetchAndStoreContacts(accountID: String) async {
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
                        for contact in parsed {
                            if let idx = allContacts.firstIndex(where: { $0.email == contact.email }) {
                                allContacts[idx] = contact
                            } else {
                                allContacts.append(contact)
                            }
                        }
                        incPageToken = response.nextPageToken
                        newSyncToken = response.nextSyncToken ?? newSyncToken
                    } while incPageToken != nil
                    print("[Serif] Incremental sync completed")
                } catch {
                    let isGone = if case GmailAPIError.httpError(410, _) = error { true } else { false }
                    if isGone {
                        print("[Serif] Sync token expired, performing full re-fetch")
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
                print("[Serif] Full fetch: loaded \(allContacts.count) contacts from Connections")
            }

            if let newSyncToken {
                try? await mailDB?.dbPool.write { db in
                    try MailDatabaseQueries.updateSyncState({ $0.contactsSyncToken = newSyncToken }, in: db)
                }
            }
        } catch {
            print("[Serif] Connections fetch error: \(error)")
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
                        for contact in parsed {
                            if let idx = allContacts.firstIndex(where: { $0.email == contact.email }) {
                                allContacts[idx] = contact
                            } else {
                                allContacts.append(contact)
                            }
                        }
                        incPageToken = response.nextPageToken
                        newOtherSyncToken = response.nextSyncToken ?? newOtherSyncToken
                    } while incPageToken != nil
                    print("[Serif] Other Contacts incremental sync completed")
                } catch {
                    let isGone = if case GmailAPIError.httpError(410, _) = error { true } else { false }
                    if isGone {
                        print("[Serif] Other Contacts sync token expired, performing full re-fetch")
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
                    print("[Serif] Loaded \(allContacts.count - beforeCount) from Other Contacts page")
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
            print("[Serif] Other Contacts fetch error: \(error)")
        }

        // Deduplicate by email and persist to GRDB
        var seen = Set<String>()
        let unique = allContacts.filter { seen.insert($0.email).inserted }
        if let mailDB {
            let syncer = BackgroundSyncer(db: mailDB)
            // Delete contacts that were removed during incremental sync
            if !deletedEmails.isEmpty {
                try? await syncer.deleteContacts(emails: Array(deletedEmails))
            }
            let tuples = unique.map { (email: $0.email, name: Optional($0.name), photoUrl: $0.photoURL, source: "people_api", resourceName: nil as String?) }
            try? await syncer.upsertContacts(tuples)
        }
        print("[Serif] Total unique contacts stored: \(unique.count)")
    }

    /// Fetches Google Workspace directory contacts (domain profiles + contacts).
    /// Gracefully skips if the directory.readonly scope isn't granted (403).
    private func fetchDirectoryPeople(accountID: String) async {
        let mailDB = try? MailDatabase.shared(for: accountID)

        do {
            let dirSyncToken: String? = try? await mailDB?.dbPool.read { db in
                try MailDatabaseQueries.syncState(in: db)?.directorySyncToken
            }
            var newDirSyncToken: String?
            var directoryContacts: [StoredContact] = []

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
                        // Will do full fetch below
                    } else {
                        throw error
                    }
                }
            }

            if dirSyncToken == nil {
                // No sync token means we haven't done initial fetch — do full fetch
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

            // Upsert directory contacts
            if let mailDB, !directoryContacts.isEmpty {
                let syncer = BackgroundSyncer(db: mailDB)
                let tuples = directoryContacts.map {
                    (email: $0.email, name: Optional($0.name), photoUrl: $0.photoURL, source: "directory", resourceName: nil as String?)
                }
                try? await syncer.upsertContacts(tuples)
            }

        } catch {
            // 403 = scope not granted — skip silently
            if case GmailAPIError.httpError(403, _) = error {
                print("[Serif] Directory contacts skipped — scope not granted")
            } else {
                print("[Serif] Directory contacts error: \(error)")
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
