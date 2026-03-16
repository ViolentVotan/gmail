import Foundation

// MARK: - Network Configuration

enum NetworkConfig {
    /// Shared URLSession for external (non-Gmail-API) requests: avatar fetches,
    /// BIMI lookups, RSVP pings, OAuth token operations, unsubscribe POST, etc.
    /// Shorter timeouts and connection limits vs URLSession.shared defaults.
    static let externalSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()
}

// MARK: - UserDefaults Keys

enum UserDefaultsKey {
    static let undoDuration = "undoDuration"
    static let appearancePreference = "appearancePreference"
    static let attachmentScanMonths = "attachmentScanMonths"
    static let isSignedIn = "isSignedIn"
    static let notificationsEnabled = "notificationsEnabled"
    static let aiLabelSuggestions = "aiLabelSuggestions"
    static let showDebugMenu = "showDebugMenu"
    static let syncDirectoryContacts = "syncDirectoryContacts"
    static let dismissedLabelSuggestions = "dismissedLabelSuggestions"
    static let emailDensity = "emailDensity"
    static let soundEffectsEnabled = "soundEffectsEnabled"

    static func signatureForNew(_ accountID: String) -> String {
        "signatureForNew.\(accountID)"
    }
    static func signatureForReply(_ accountID: String) -> String {
        "signatureForReply.\(accountID)"
    }
    static func attachmentExclusionRules(_ accountID: String) -> String {
        "attachmentExclusionRules.\(accountID)"
    }
}

// MARK: - Gmail System Labels

enum GmailSystemLabel {
    static let inbox = "INBOX"
    static let starred = "STARRED"
    static let unread = "UNREAD"
    static let sent = "SENT"
    static let draft = "DRAFT"
    static let spam = "SPAM"
    static let trash = "TRASH"
    static let important = "IMPORTANT"

    static let category_personal = "CATEGORY_PERSONAL"
    static let category_social = "CATEGORY_SOCIAL"
    static let category_promotions = "CATEGORY_PROMOTIONS"
    static let category_updates = "CATEGORY_UPDATES"
    static let category_forums = "CATEGORY_FORUMS"
}
