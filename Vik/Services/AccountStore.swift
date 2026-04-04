import Foundation

/// Persists the list of connected accounts to UserDefaults.
/// Tokens are stored separately in the Keychain via TokenStore.
/// Security note: Account metadata (email, name) stored in UserDefaults for quick access.
/// OAuth tokens are in Keychain (encrypted). Profile picture URLs are sanitized below.
/// All access is confined to @MainActor, eliminating the need for @unchecked Sendable.
@MainActor
final class AccountStore {
    static let shared = AccountStore()

    static let accentPalette = [
        "#FF6B6B", "#4ECDC4", "#45B7D1", "#F7DC6F",
        "#BB8FCE", "#F0932B", "#6C5CE7", "#A3CB38"
    ]

    private init() { migrateColors() }

    // Profile metadata only (no tokens/content) — UserDefaults acceptable for quick access
    private let key = "com.vikingz.vik.accounts"
    private let selectedAccountIDKey = "com.vikingz.vik.selectedAccountID"
    private var _cachedAccounts: [GmailAccount]?

    /// The currently selected account ID, kept in sync by AppCoordinator.
    /// Used by Settings scene (outside WindowGroup) to show the right account.
    var selectedAccountID: String? {
        get { UserDefaults.standard.string(forKey: selectedAccountIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: selectedAccountIDKey) }
    }

    var accounts: [GmailAccount] {
        get {
            if let cached = _cachedAccounts { return cached }
            guard
                let data = UserDefaults.standard.data(forKey: key),
                let decoded = try? JSONDecoder().decode([GmailAccount].self, from: data)
            else {
                _cachedAccounts = []
                return []
            }
            _cachedAccounts = decoded
            return decoded
        }
        set {
            let sanitized = newValue.map { Self.sanitizeProfileURL($0) }
            _cachedAccounts = sanitized
            let data = try? JSONEncoder().encode(sanitized)
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Clears the in-memory cache so the next `accounts` read re-decodes from UserDefaults.
    /// Call when an external change (e.g., another window) may have modified the persisted accounts.
    func invalidateCache() {
        _cachedAccounts = nil
    }

    func add(_ account: GmailAccount) {
        var acct = account
        if acct.accentColor == nil {
            let used = Set(accounts.compactMap(\.accentColor))
            acct.accentColor = Self.accentPalette.first { !used.contains($0) }
                ?? Self.accentPalette[accounts.count % Self.accentPalette.count]
        }
        var all = accounts
        all.removeAll { $0.id == acct.id }
        all.append(acct)
        accounts = all
    }

    /// Removes an account from the persisted list.
    /// All service cleanup (tokens, caches, per-account stores) is performed by
    /// AppCoordinator.handleAccountsChange after this returns.
    func remove(id: String) {
        accounts = accounts.filter { $0.id != id }
    }

    func setAsDefault(id: String) {
        var all = accounts
        guard let idx = all.firstIndex(where: { $0.id == id }), idx != 0 else { return }
        let account = all.remove(at: idx)
        all.insert(account, at: 0)
        accounts = all
    }


    func moveUp(id: String) {
        var all = accounts
        guard let idx = all.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        all.swapAt(idx, idx - 1)
        accounts = all
    }


    func moveDown(id: String) {
        var all = accounts
        guard let idx = all.firstIndex(where: { $0.id == id }), idx < all.count - 1 else { return }
        all.swapAt(idx, idx + 1)
        accounts = all
    }


    func reorder(from source: IndexSet, to destination: Int) {
        var all = accounts
        all.move(fromOffsets: source, toOffset: destination)
        accounts = all
    }

    func setAccentColor(id: String, hex: String) {
        var all = accounts
        if let idx = all.firstIndex(where: { $0.id == id }) {
            all[idx].accentColor = hex
            accounts = all
        }
    }

    /// Strips query parameters from profile picture URLs to avoid persisting potential auth tokens.
    private static func sanitizeProfileURL(_ account: GmailAccount) -> GmailAccount {
        guard let url = account.profilePictureURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return account }
        components.query = nil
        return GmailAccount(
            email: account.email,
            displayName: account.displayName,
            profilePictureURL: components.url,
            accentColor: account.accentColor
        )
    }

    /// Assigns accent colors to any accounts that don't have one yet.
    private func migrateColors() {
        var all = accounts
        var changed = false
        var used = Set(all.compactMap(\.accentColor))
        for i in all.indices where all[i].accentColor == nil {
            let color = Self.accentPalette.first { !used.contains($0) }
                ?? Self.accentPalette[i % Self.accentPalette.count]
            all[i].accentColor = color
            used.insert(color)
            changed = true
        }
        if changed { accounts = all }
    }
}
