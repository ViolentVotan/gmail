import Foundation
internal import GRDB
private import os

/// Fetches contacts and photos from the Google People API.
@MainActor
final class PeopleAPIService {
    nonisolated private static let logger = Logger(category: "PeopleAPI")
    static let shared = PeopleAPIService()
    private init() {}

    /// Sync tokens expire after 7 days per Google docs. Proactively refresh at 6 days.
    nonisolated private static let syncTokenMaxAge: TimeInterval = 6 * 24 * 3600
    nonisolated private static let baseURL = "https://people.googleapis.com/v1"

    /// Loads contacts: uses local cache if available, otherwise fetches from network.
    /// The caller must supply the `BackgroundSyncer` for the account so contact
    /// writes are serialized through the same actor instance used by the sync engine.
    func loadContactPhotos(accountID: String, syncer: BackgroundSyncer) async {
        let local: [StoredContact] = (try? await MailDatabase.shared(for: accountID).dbPool.read { db in
            try MailDatabaseQueries.allContacts(limit: 10_000, in: db).map {
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
        if UserDefaults.standard.bool(forKey: UserDefaultsKey.syncDirectoryContacts) {
            await fetchDirectoryPeople(accountID: accountID, syncer: syncer)
        }
    }

    /// Extracts contact tuples from a PersonResource array, updating the photo cache.
    /// Returns tuples ready for `BackgroundSyncer.upsertContacts`.
    nonisolated private func parseContacts(
        from persons: [PersonResource],
        source: String = "people_api"
    ) -> [(email: String, name: String?, photoUrl: String?, source: String, resourceName: String?)] {
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
                contacts.append((email: lowered, name: displayName, photoUrl: photoURL, source: source, resourceName: nil))
            }
        }
        return contacts
    }

    // MARK: - Paginated Sync Helper

    /// Configuration for a paginated People API sync source.
    private struct ContactSyncSource<Response: PaginatedPeopleResponse>: Sendable {
        let label: String
        let source: String
        let incrementalURL: @Sendable (_ encodedSyncToken: String) -> String
        let fullFetchURL: @Sendable () -> String
        let readSyncToken: @Sendable (AccountSyncStateRecord?) -> String?
        let readSyncTokenTimestamp: @Sendable (AccountSyncStateRecord?) -> Double?
        let clearSyncToken: @Sendable (inout AccountSyncStateRecord) -> Void
        let saveSyncToken: @Sendable (inout AccountSyncStateRecord, _ token: String) -> Void
        let handleDeletes: Bool
        let evictPhotoCacheOnDelete: Bool
        let preservePhotosOnUpsert: Bool
        let responseType: Response.Type
    }

    /// Result of a paginated sync, indicating whether a full re-fetch was performed.
    private enum SyncResult: Sendable {
        case incremental
        case fullFetch
    }

    /// Generic paginated sync: incremental (with sync token) or full re-fetch.
    /// Each page is written to the DB immediately — a crash mid-pagination loses
    /// the sync token (forcing a full re-fetch on restart) but contacts fetched so
    /// far are already persisted. The sync token is only saved after all pages
    /// complete, matching the pattern used by `performInitialSync` for messages.
    @concurrent private func paginatedSync<Response: PaginatedPeopleResponse>(
        source config: ContactSyncSource<Response>,
        accountID: String,
        syncer: BackgroundSyncer,
        mailDB: MailDatabase?
    ) async throws -> SyncResult {
        var newSyncToken: String?
        var needsFullFetch: Bool

        let syncState = try? await mailDB?.dbPool.read { db in
            try MailDatabaseQueries.syncState(in: db)
        }
        let syncToken = config.readSyncToken(syncState)
        let tokenExpired = config.readSyncTokenTimestamp(syncState).map {
            Date().timeIntervalSince1970 - $0 > Self.syncTokenMaxAge
        } ?? false
        needsFullFetch = syncToken == nil || tokenExpired
        if tokenExpired {
            Self.logger.info("\(config.label) sync token older than 6 days, forcing full re-fetch")
        }

        if let syncToken, !needsFullFetch {
            // Incremental sync — write per-page
            do {
                var pageToken: String? = nil
                repeat {
                    let encoded = syncToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? syncToken
                    var urlStr = config.incrementalURL(encoded)
                    appendPageToken(pageToken, to: &urlStr)
                    let response: Response = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)

                    if config.handleDeletes {
                        let deleted = (response.persons ?? [])
                            .filter { $0.metadata?.deleted == true }
                            .flatMap { $0.emailAddresses?.compactMap { $0.value?.lowercased() } ?? [] }
                        if !deleted.isEmpty {
                            do {
                                try await syncer.deleteContacts(emails: deleted)
                            } catch {
                                Self.logger.error("Contact DB write failed: \(error, privacy: .public)")
                            }
                            if config.evictPhotoCacheOnDelete {
                                for email in deleted { ContactPhotoCache.shared.remove(email) }
                            }
                        }
                    }

                    let nonDeleted = (response.persons ?? []).filter { $0.metadata?.deleted != true }
                    let parsed = parseContacts(from: nonDeleted, source: config.source)
                    do {
                        if config.preservePhotosOnUpsert {
                            try await syncer.upsertContactsPreservingPhotos(parsed)
                        } else {
                            try await syncer.upsertContacts(parsed)
                        }
                    } catch {
                        Self.logger.error("Contact DB write failed: \(error, privacy: .public)")
                    }

                    pageToken = response.nextPageToken
                    newSyncToken = response.nextSyncToken ?? newSyncToken
                    if pageToken != nil {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                } while pageToken != nil
                Self.logger.info("\(config.label) incremental sync completed")
            } catch {
                let isGone = if case GmailAPIError.httpError(410, _) = error { true } else { false }
                if isGone {
                    Self.logger.warning("\(config.label) sync token expired, performing full re-fetch")
                    do {
                        try await mailDB?.dbPool.write { db in
                            try MailDatabaseQueries.updateSyncState({ config.clearSyncToken(&$0) }, in: db)
                        }
                    } catch {
                        Self.logger.warning("Failed to clear expired \(config.label) sync token: \(error, privacy: .public)")
                    }
                    needsFullFetch = true
                } else {
                    throw error
                }
            }
        }

        if needsFullFetch {
            // Full fetch — write per-page
            newSyncToken = nil
            var totalStored = 0
            var pageToken: String? = nil
            repeat {
                var urlStr = config.fullFetchURL()
                appendPageToken(pageToken, to: &urlStr)
                let response: Response = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)

                let parsed = parseContacts(from: response.persons ?? [], source: config.source)
                do {
                    if config.preservePhotosOnUpsert {
                        try await syncer.upsertContactsPreservingPhotos(parsed)
                    } else {
                        try await syncer.upsertContacts(parsed)
                    }
                } catch {
                    Self.logger.error("Contact DB write failed: \(error, privacy: .public)")
                }
                totalStored += parsed.count

                pageToken = response.nextPageToken
                newSyncToken = response.nextSyncToken ?? newSyncToken
                if pageToken != nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } while pageToken != nil
            Self.logger.info("\(config.label) full fetch: stored \(totalStored, privacy: .public) contacts")
        }

        // Save sync token after all pages succeeded
        if let token = newSyncToken {
            do {
                try await mailDB?.dbPool.write { db in
                    try MailDatabaseQueries.updateSyncState({ config.saveSyncToken(&$0, token) }, in: db)
                }
            } catch {
                Self.logger.warning("Failed to save \(config.label) sync token: \(error, privacy: .public)")
            }
        }

        return needsFullFetch ? .fullFetch : .incremental
    }

    /// Fetches contacts from People API and persists them per-page.
    @concurrent private func fetchAndStoreContacts(accountID: String, syncer: BackgroundSyncer) async {
        let syncStartTime = Date().timeIntervalSince1970
        let mailDB = try? await MailDatabase.shared(for: accountID)

        let connectionsSource = ContactSyncSource(
            label: "Contacts",
            source: "people_api",
            incrementalURL: { syncToken in
                "\(Self.baseURL)/people/me/connections"
                    + "?personFields=metadata,names,emailAddresses,photos&syncToken=\(syncToken)"
                    + "&pageSize=1000&sortOrder=LAST_MODIFIED_ASCENDING"
                    + "&fields=\(Self.connectionsFields)"
            },
            fullFetchURL: {
                "\(Self.baseURL)/people/me/connections"
                    + "?personFields=metadata,names,emailAddresses,photos&pageSize=1000"
                    + "&requestSyncToken=true&sortOrder=LAST_MODIFIED_ASCENDING"
                    + "&fields=\(Self.connectionsFields)"
            },
            readSyncToken: { $0?.contactsSyncToken },
            readSyncTokenTimestamp: { $0?.contactsSyncTokenAt },
            clearSyncToken: {
                $0.contactsSyncToken = nil
                $0.contactsSyncTokenAt = nil
            },
            saveSyncToken: {
                $0.contactsSyncToken = $1
                $0.contactsSyncTokenAt = Date().timeIntervalSince1970
            },
            handleDeletes: true,
            evictPhotoCacheOnDelete: true,
            preservePhotosOnUpsert: false,
            responseType: PeopleConnectionsResponse.self
        )

        let otherContactsSource = ContactSyncSource(
            label: "Other Contacts",
            source: "people_api",
            incrementalURL: { syncToken in
                "\(Self.baseURL)/otherContacts"
                    + "?readMask=metadata,names,emailAddresses&syncToken=\(syncToken)"
                    + "&pageSize=1000&fields=\(Self.otherContactsFields)"
            },
            fullFetchURL: {
                "\(Self.baseURL)/otherContacts"
                    + "?readMask=metadata,names,emailAddresses&pageSize=1000"
                    + "&requestSyncToken=true&fields=\(Self.otherContactsFields)"
            },
            readSyncToken: { $0?.otherContactsSyncToken },
            readSyncTokenTimestamp: { $0?.otherContactsSyncTokenAt },
            clearSyncToken: {
                $0.otherContactsSyncToken = nil
                $0.otherContactsSyncTokenAt = nil
            },
            saveSyncToken: {
                $0.otherContactsSyncToken = $1
                $0.otherContactsSyncTokenAt = Date().timeIntervalSince1970
            },
            handleDeletes: true,
            evictPhotoCacheOnDelete: false,
            preservePhotosOnUpsert: true,
            responseType: OtherContactsResponse.self
        )

        // 1. Fetch "My Contacts" via Connections
        var contactsFetchSucceeded = false
        var didFullConnectionsFetch = false
        do {
            let result = try await paginatedSync(
                source: connectionsSource, accountID: accountID, syncer: syncer, mailDB: mailDB
            )
            contactsFetchSucceeded = true
            didFullConnectionsFetch = result == .fullFetch
        } catch {
            Self.logger.error("Connections fetch error: \(error, privacy: .public)")
        }

        // 2. Fetch "Other Contacts" (auto-created from email interactions)
        // Note: readMask omits "photos" — Other Contacts don't support photo fields.
        // Uses photo-preserving upsert to avoid overwriting Connections photos with nil.
        var didFullOtherContactsFetch = false
        do {
            let result = try await paginatedSync(
                source: otherContactsSource, accountID: accountID, syncer: syncer, mailDB: mailDB
            )
            didFullOtherContactsFetch = result == .fullFetch
        } catch {
            Self.logger.error("Other Contacts fetch error: \(error, privacy: .public)")
        }

        // 3. Purge stale people_api contacts after a full re-fetch.
        // When both Connections and Other Contacts completed a full fetch, all live
        // contacts were upserted above — anything with updated_at < syncStartTime
        // no longer exists upstream and can be safely pruned.
        if didFullConnectionsFetch && didFullOtherContactsFetch {
            do {
                let pruned = try await mailDB?.dbPool.write { db -> Int in
                    try ContactRecord
                        .filter(Column("source") == "people_api")
                        .filter(Column("updated_at") < syncStartTime)
                        .deleteAll(db)
                }
                if let pruned, pruned > 0 {
                    Self.logger.info("Pruned \(pruned, privacy: .public) stale people_api contacts")
                }
            } catch {
                Self.logger.error("Failed to prune stale people_api contacts: \(error, privacy: .public)")
            }
        }

        if contactsFetchSucceeded {
            Self.logger.info("Contact sync complete")
        }
    }

    /// Fetches Google Workspace directory contacts (domain profiles + contacts).
    /// Writes each page to DB immediately. Gracefully skips if the directory.readonly
    /// scope isn't granted (403).
    @concurrent private func fetchDirectoryPeople(accountID: String, syncer: BackgroundSyncer) async {
        let mailDB = try? await MailDatabase.shared(for: accountID)
        let syncStartTime = Date().timeIntervalSince1970

        let directorySource = ContactSyncSource(
            label: "Directory",
            source: "directory",
            incrementalURL: { syncToken in
                "\(Self.baseURL)/people:listDirectoryPeople"
                    + "?sources=DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"
                    + "&sources=DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"
                    + "&readMask=metadata,names,emailAddresses,photos"
                    + "&syncToken=\(syncToken)"
                    + "&pageSize=1000&fields=\(Self.directoryFields)"
            },
            fullFetchURL: {
                "\(Self.baseURL)/people:listDirectoryPeople"
                    + "?sources=DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"
                    + "&sources=DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"
                    + "&readMask=metadata,names,emailAddresses,photos"
                    + "&requestSyncToken=true&pageSize=1000"
                    + "&fields=\(Self.directoryFields)"
            },
            readSyncToken: { $0?.directorySyncToken },
            readSyncTokenTimestamp: { _ in nil },
            clearSyncToken: { $0.directorySyncToken = nil },
            saveSyncToken: { $0.directorySyncToken = $1 },
            handleDeletes: false,
            evictPhotoCacheOnDelete: false,
            preservePhotosOnUpsert: false,
            responseType: DirectoryPeopleResponse.self
        )

        do {
            let result = try await paginatedSync(
                source: directorySource, accountID: accountID, syncer: syncer, mailDB: mailDB
            )
            // Purge directory contacts not seen in this full re-fetch
            if result == .fullFetch {
                do {
                    let pruned = try await mailDB?.dbPool.write { db -> Int in
                        try ContactRecord
                            .filter(Column("source") == "directory")
                            .filter(Column("updated_at") < syncStartTime)
                            .deleteAll(db)
                    }
                    if let pruned, pruned > 0 {
                        Self.logger.info("Pruned \(pruned, privacy: .public) stale directory contacts")
                    }
                } catch {
                    Self.logger.error("Failed to prune stale directory contacts: \(error, privacy: .public)")
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

    // MARK: - Person Detail Enrichment

    nonisolated private static let personDetailFields = "organizations,phoneNumbers,addresses"

    @concurrent
    func fetchPersonDetails(resourceName: String, accountID: String) async -> PersonDetails? {
        let segments = resourceName.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let urlStr = "\(Self.baseURL)/\(segments)?personFields=\(Self.personDetailFields)"
        do {
            let person: PersonResource = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)
            let org = person.organizations?.first
            let phone = person.phoneNumbers?.first
            let addr = person.addresses?.first
            let location: String? = addr.flatMap { a in
                a.formattedValue ?? [a.city, a.region, a.country].compactMap { $0 }.joined(separator: ", ").nilIfEmpty
            }
            let details = PersonDetails(
                organization: [org?.title, org?.name].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                title: org?.title,
                phoneNumber: phone?.canonicalForm ?? phone?.value,
                location: location
            )
            guard details.organization != nil || details.phoneNumber != nil || details.location != nil else {
                return nil
            }
            return details
        } catch {
            Self.logger.debug("Person detail enrichment failed for \(resourceName, privacy: .private): \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - URL Helpers

    nonisolated private func appendPageToken(_ token: String?, to url: inout String) {
        guard let token else { return }
        url += "&pageToken=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)"
    }

    // MARK: - Response Field Masks

    /// Partial-response `fields` filter for connections.list — limits the response
    /// envelope to only the fields we decode, avoiding unnecessary metadata transfer.
    nonisolated private static let connectionsFields = [
        "connections(emailAddresses/value,names/displayName,photos(url,default),metadata/deleted)",
        "nextPageToken",
        "nextSyncToken",
    ].joined(separator: ",")

    /// Partial-response `fields` filter for otherContacts.list.
    nonisolated private static let otherContactsFields = [
        "otherContacts(emailAddresses/value,names/displayName,metadata/deleted)",
        "nextPageToken",
        "nextSyncToken",
    ].joined(separator: ",")

    /// Partial-response `fields` filter for people:listDirectoryPeople.
    nonisolated private static let directoryFields = [
        "people(emailAddresses/value,names/displayName,photos(url,default),metadata/deleted)",
        "nextPageToken",
        "nextSyncToken",
    ].joined(separator: ",")
}

// MARK: - People API response models

private protocol PaginatedPeopleResponse: Decodable, Sendable {
    var persons: [PersonResource]? { get }
    var nextPageToken: String? { get }
    var nextSyncToken: String? { get }
}

struct PeopleConnectionsResponse: Decodable, Sendable, PaginatedPeopleResponse {
    let connections: [PersonResource]?
    let nextPageToken: String?
    let nextSyncToken: String?
    var persons: [PersonResource]? { connections }
}

struct OtherContactsResponse: Decodable, Sendable, PaginatedPeopleResponse {
    let otherContacts: [PersonResource]?
    let nextPageToken: String?
    let nextSyncToken: String?
    var persons: [PersonResource]? { otherContacts }
}

struct DirectoryPeopleResponse: Decodable, Sendable, PaginatedPeopleResponse {
    let people: [PersonResource]?
    let nextPageToken: String?
    let nextSyncToken: String?
    var persons: [PersonResource]? { people }
}

struct PersonMetadata: Decodable {
    let deleted: Bool?
}

struct PersonResource: Decodable {
    let metadata: PersonMetadata?
    let emailAddresses: [PersonEmail]?
    let photos: [PersonPhoto]?
    let names: [PersonName]?
    let organizations: [PersonOrganization]?
    let phoneNumbers: [PersonPhoneNumber]?
    let addresses: [PersonAddress]?
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

struct PersonOrganization: Decodable {
    let name: String?
    let title: String?
}

struct PersonPhoneNumber: Decodable {
    let value: String?
    let canonicalForm: String?
}

struct PersonAddress: Decodable {
    let formattedValue: String?
    let city: String?
    let region: String?
    let country: String?
}

struct PersonDetails: Sendable {
    let organization: String?
    let title: String?
    let phoneNumber: String?
    let location: String?
}
