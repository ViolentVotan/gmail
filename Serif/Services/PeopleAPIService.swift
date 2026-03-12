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

        // 1. Fetch "My Contacts" via connections
        do {
            let syncToken = ContactStore.shared.syncToken(for: accountID)
            var newSyncToken: String?
            var needsFullFetch = syncToken == nil

            if let syncToken, !needsFullFetch {
                allContacts = ContactStore.shared.contacts(for: accountID)
                do {
                    var incPageToken: String? = nil
                    repeat {
                        var urlStr = "https://people.googleapis.com/v1/people/me/connections"
                            + "?personFields=names,emailAddresses,photos&syncToken=\(syncToken)"
                            + "&pageSize=1000"
                        if let pt = incPageToken { urlStr += "&pageToken=\(pt)" }
                        let response: PeopleConnectionsResponse = try await GmailAPIClient.shared.requestURL(urlStr, accountID: accountID)
                        let parsed = parseContacts(from: response.connections ?? [])
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
                        ContactStore.shared.setSyncToken(nil, for: accountID)
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
                        + "?personFields=names,emailAddresses,photos&pageSize=1000"
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
                ContactStore.shared.setSyncToken(newSyncToken, for: accountID)
            }
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
                allContacts.append(contentsOf: parseContacts(from: response.otherContacts ?? []))
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
    let nextSyncToken: String?
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
