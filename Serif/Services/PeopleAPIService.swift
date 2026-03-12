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
