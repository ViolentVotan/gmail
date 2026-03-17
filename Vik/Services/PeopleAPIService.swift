import Foundation
internal import GRDB
private import os

/// Fetches contacts and photos from the Google People API.
@MainActor
final class PeopleAPIService {
    nonisolated private static let logger = Logger(subsystem: "com.vikingz.vik", category: "PeopleAPI")
    static let shared = PeopleAPIService()
    private init() {}

    /// Sync tokens expire after 7 days per Google docs. Proactively refresh at 6 days.
    private static let syncTokenMaxAge: TimeInterval = 6 * 24 * 3600

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

    /// Extracts contact tuples from a PersonResource array, updating the photo cache.
    /// Returns tuples ready for `BackgroundSyncer.upsertContacts`.
    private func parseContacts(from persons: [PersonResource]) -> [(email: String, name: String?, photoUrl: String?, source: String, resourceName: String?)] {
        var contacts: [(email: String, name: String?, photoUrl: String?, source: String, resourceName: String?)] = []
        for person in persons {
            let displayName = person.names?.first?.displayName ?? ""
            let photoURL = person.photos?.first(where: { $0.default != true })?.url
            for addr in person.emailAddresses ?? [] {
                guard let email = addr.value, !email.isEmpty else { continue }
                let lowered = email.lowercased()
                if let url = photoURL {
                    ContactPhotoCache.shared.set(url, for: lowered)
                }
                contacts.append((email: lowered, name: displayName, photoUrl: photoURL, source: "people_api", resourceName: nil))
            }
        }
        return contacts
    }

    /// Fetches contacts from People API and persists them per-page.
    /// Uses sync tokens for incremental updates when available.
    /// Each page is written to the DB immediately — a crash mid-pagination loses
    /// the sync token (forcing a full re-fetch on restart) but contacts fetched so
    /// far are already persisted. The sync token is only saved after all pages
    /// complete, matching the pattern used by `performInitialSync` for messages.
    private func fetchAndStoreContacts(accountID: String, syncer: BackgroundSyncer) async {
        var newContactsSyncToken: String?
        var newOtherSyncToken: String?
        var contactsFetchSucceeded = false

        let mailDB = try? MailDatabase.shared(for: accountID)

        // 1. Fetch "My Contacts" via Connections
        do {
            let syncState = try? await mailDB?.dbPool.read { db in
                try MailDatabaseQueries.syncState(in: db)
            }
            let syncToken = syncState?.contactsSyncToken
            let tokenExpired = syncState?.contactsSyncTokenAt.map {
                Date().timeIntervalSince1970 - $0 > Self.syncTokenMaxAge
            } ?? false
            var needsFullFetch = syncToken == nil || tokenExpired
            if tokenExpired {
                Self.logger.info("Contacts sync token older than 6 days, forcing full re-fetch")
            }

            if let syncToken, !needsFullFetch {
                // Incremental sync — write per-page
                do {
                    var pageToken: String? = nil
                    repeat {
                        let encoded = syncToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? syncToken
                        var urlStr = "https://people.googleapis.com/v1/people/me/connections"
                            + "?personFields=metadata,names,emailAddresses,photos&syncToken=\(encoded)"
                            + "&pageSize=1000"
                        if let pt = pageToken { urlStr += "&pageToken=\(pt)" }
                        let response: PeopleConnectionsResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)

                        // Delete removed contacts from this page
                        let deleted = (response.connections ?? [])
                            .filter { $0.metadata?.deleted == true }
                            .flatMap { $0.emailAddresses?.compactMap { $0.value?.lowercased() } ?? [] }
                        if !deleted.isEmpty {
                            try? await syncer.deleteContacts(emails: deleted)
                            for email in deleted { ContactPhotoCache.shared.remove(email) }
                        }

                        // Upsert new/updated contacts from this page
                        let nonDeleted = (response.connections ?? []).filter { $0.metadata?.deleted != true }
                        let parsed = parseContacts(from: nonDeleted)
                        try? await syncer.upsertContacts(parsed)

                        pageToken = response.nextPageToken
                        newContactsSyncToken = response.nextSyncToken ?? newContactsSyncToken
                        if pageToken != nil {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    } while pageToken != nil
                    contactsFetchSucceeded = true
                    Self.logger.info("Contacts incremental sync completed")
                } catch {
                    let isGone = if case GmailAPIError.httpError(410, _) = error { true } else { false }
                    if isGone {
                        Self.logger.warning("Sync token expired, performing full re-fetch")
                        try? await mailDB?.dbPool.write { db in
                            try MailDatabaseQueries.updateSyncState({
                                $0.contactsSyncToken = nil
                                $0.contactsSyncTokenAt = nil
                            }, in: db)
                        }
                        needsFullFetch = true
                    } else {
                        throw error
                    }
                }
            }

            if needsFullFetch {
                // Full fetch — write each page to DB as it arrives
                newContactsSyncToken = nil
                var totalStored = 0
                var pageToken: String? = nil
                do {
                    repeat {
                        var urlStr = "https://people.googleapis.com/v1/people/me/connections"
                            + "?personFields=metadata,names,emailAddresses,photos&pageSize=1000"
                            + "&requestSyncToken=true"
                        if let pt = pageToken { urlStr += "&pageToken=\(pt)" }
                        let response: PeopleConnectionsResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)

                        let parsed = parseContacts(from: response.connections ?? [])
                        try? await syncer.upsertContacts(parsed)
                        totalStored += parsed.count

                        pageToken = response.nextPageToken
                        newContactsSyncToken = response.nextSyncToken ?? newContactsSyncToken
                        if pageToken != nil {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    } while pageToken != nil
                    contactsFetchSucceeded = true
                    Self.logger.info("Full fetch: stored \(totalStored, privacy: .public) contacts from Connections")
                } catch {
                    Self.logger.error("Full Connections fetch failed: \(error, privacy: .public)")
                    return
                }
            }

        } catch {
            Self.logger.error("Connections fetch error: \(error, privacy: .public)")
        }

        // 2. Fetch "Other Contacts" (auto-created from email interactions)
        // Note: readMask omits "photos" — Other Contacts don't support photo fields.
        // Uses photo-preserving upsert to avoid overwriting Connections photos with nil.
        do {
            let otherState = try? await mailDB?.dbPool.read { db in
                try MailDatabaseQueries.syncState(in: db)
            }
            let otherSyncToken = otherState?.otherContactsSyncToken
            let otherTokenExpired = otherState?.otherContactsSyncTokenAt.map {
                Date().timeIntervalSince1970 - $0 > Self.syncTokenMaxAge
            } ?? false
            var needsFullOtherFetch = otherSyncToken == nil || otherTokenExpired
            if otherTokenExpired {
                Self.logger.info("Other Contacts sync token older than 6 days, forcing full re-fetch")
            }

            if let otherSyncToken, !needsFullOtherFetch {
                // Incremental sync — write per-page
                do {
                    var pageToken: String? = nil
                    repeat {
                        let encoded = otherSyncToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? otherSyncToken
                        var urlStr = "https://people.googleapis.com/v1/otherContacts"
                            + "?readMask=metadata,names,emailAddresses&syncToken=\(encoded)"
                            + "&pageSize=1000"
                        if let pt = pageToken { urlStr += "&pageToken=\(pt)" }
                        let response: OtherContactsResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)

                        // Delete removed contacts from this page
                        let deleted = (response.otherContacts ?? [])
                            .filter { $0.metadata?.deleted == true }
                            .flatMap { $0.emailAddresses?.compactMap { $0.value?.lowercased() } ?? [] }
                        if !deleted.isEmpty {
                            try? await syncer.deleteContacts(emails: deleted)
                        }

                        // Upsert non-deleted, preserving photos from Connections
                        let nonDeleted = (response.otherContacts ?? []).filter { $0.metadata?.deleted != true }
                        let parsed = parseContacts(from: nonDeleted)
                        try? await syncer.upsertContactsPreservingPhotos(parsed)

                        pageToken = response.nextPageToken
                        newOtherSyncToken = response.nextSyncToken ?? newOtherSyncToken
                        if pageToken != nil {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    } while pageToken != nil
                    Self.logger.info("Other Contacts incremental sync completed")
                } catch {
                    let isGone = if case GmailAPIError.httpError(410, _) = error { true } else { false }
                    if isGone {
                        Self.logger.warning("Other Contacts sync token expired, performing full re-fetch")
                        try? await mailDB?.dbPool.write { db in
                            try MailDatabaseQueries.updateSyncState({
                                $0.otherContactsSyncToken = nil
                                $0.otherContactsSyncTokenAt = nil
                            }, in: db)
                        }
                        needsFullOtherFetch = true
                    } else {
                        throw error
                    }
                }
            }

            if needsFullOtherFetch {
                // Full fetch — write per-page with photo preservation
                var pageToken: String? = nil
                do {
                    repeat {
                        var urlStr = "https://people.googleapis.com/v1/otherContacts"
                            + "?readMask=metadata,names,emailAddresses&pageSize=1000"
                            + "&requestSyncToken=true"
                        if let pt = pageToken { urlStr += "&pageToken=\(pt)" }
                        let response: OtherContactsResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)

                        let parsed = parseContacts(from: response.otherContacts ?? [])
                        try? await syncer.upsertContactsPreservingPhotos(parsed)

                        pageToken = response.nextPageToken
                        newOtherSyncToken = response.nextSyncToken ?? newOtherSyncToken
                        if pageToken != nil {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    } while pageToken != nil
                } catch {
                    Self.logger.error("Full Other Contacts fetch failed: \(error, privacy: .public)")
                    return
                }
            }

        } catch {
            Self.logger.error("Other Contacts fetch error: \(error, privacy: .public)")
        }

        // 3. Advance sync tokens after all pages succeeded.
        // Tokens are only available from the last page response — saving them here
        // ensures we never advance a token without having stored all its contacts.
        if let token = newContactsSyncToken {
            try? await mailDB?.dbPool.write { db in
                try MailDatabaseQueries.updateSyncState({
                    $0.contactsSyncToken = token
                    $0.contactsSyncTokenAt = Date().timeIntervalSince1970
                }, in: db)
            }
        }
        if let token = newOtherSyncToken {
            try? await mailDB?.dbPool.write { db in
                try MailDatabaseQueries.updateSyncState({
                    $0.otherContactsSyncToken = token
                    $0.otherContactsSyncTokenAt = Date().timeIntervalSince1970
                }, in: db)
            }
        }
        if contactsFetchSucceeded {
            Self.logger.info("Contact sync complete")
        }
    }

    /// Fetches Google Workspace directory contacts (domain profiles + contacts).
    /// Writes each page to DB immediately. Gracefully skips if the directory.readonly
    /// scope isn't granted (403).
    private func fetchDirectoryPeople(accountID: String, syncer: BackgroundSyncer) async {
        let mailDB = try? MailDatabase.shared(for: accountID)

        do {
            let dirSyncToken: String? = try? await mailDB?.dbPool.read { db in
                try MailDatabaseQueries.syncState(in: db)?.directorySyncToken
            }
            var newDirSyncToken: String?
            var needsFullDirFetch = dirSyncToken == nil

            if let dirSyncToken {
                // Incremental sync — write per-page
                do {
                    var pageToken: String? = nil
                    repeat {
                        let encoded = dirSyncToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dirSyncToken
                        var urlStr = "https://people.googleapis.com/v1/people:listDirectoryPeople"
                            + "?sources=DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"
                            + "&sources=DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"
                            + "&readMask=metadata,names,emailAddresses,photos"
                            + "&syncToken=\(encoded)"
                            + "&pageSize=1000"
                        if let pt = pageToken { urlStr += "&pageToken=\(pt)" }
                        let response: DirectoryPeopleResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)

                        let parsed = parseDirectoryContacts(from: response.people ?? [])
                        try? await syncer.upsertContacts(parsed)

                        pageToken = response.nextPageToken
                        newDirSyncToken = response.nextSyncToken ?? newDirSyncToken
                        if pageToken != nil {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    } while pageToken != nil
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
                // Full fetch — write per-page
                var pageToken: String? = nil
                repeat {
                    var urlStr = "https://people.googleapis.com/v1/people:listDirectoryPeople"
                        + "?sources=DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"
                        + "&sources=DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"
                        + "&readMask=metadata,names,emailAddresses,photos"
                        + "&requestSyncToken=true&pageSize=1000"
                    if let pt = pageToken { urlStr += "&pageToken=\(pt)" }
                    let response: DirectoryPeopleResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)

                    let parsed = parseDirectoryContacts(from: response.people ?? [])
                    try? await syncer.upsertContacts(parsed)

                    pageToken = response.nextPageToken
                    newDirSyncToken = response.nextSyncToken ?? newDirSyncToken
                    if pageToken != nil {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                } while pageToken != nil
            }

            // Persist the sync token after all pages succeeded.
            if let token = newDirSyncToken {
                try? await mailDB?.dbPool.write { db in
                    try MailDatabaseQueries.updateSyncState({ $0.directorySyncToken = token }, in: db)
                }
            }

        } catch {
            if case GmailAPIError.httpError(403, _) = error {
                Self.logger.info("Directory contacts skipped — scope not granted")
            } else {
                Self.logger.error("Directory contacts error: \(error, privacy: .public)")
            }
        }
    }

    /// Extracts contact tuples from directory PersonResources with "directory" source.
    private func parseDirectoryContacts(from persons: [PersonResource]) -> [(email: String, name: String?, photoUrl: String?, source: String, resourceName: String?)] {
        var contacts: [(email: String, name: String?, photoUrl: String?, source: String, resourceName: String?)] = []
        for person in persons {
            let displayName = person.names?.first?.displayName ?? ""
            let photoURL = person.photos?.first(where: { $0.default != true })?.url
            for addr in person.emailAddresses ?? [] {
                guard let email = addr.value, !email.isEmpty else { continue }
                let lowered = email.lowercased()
                if let url = photoURL {
                    ContactPhotoCache.shared.set(url, for: lowered)
                }
                contacts.append((email: lowered, name: displayName, photoUrl: photoURL, source: "directory", resourceName: nil))
            }
        }
        return contacts
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
