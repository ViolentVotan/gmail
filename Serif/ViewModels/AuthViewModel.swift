import SwiftUI

/// Manages account sign-in, sign-out, and the list of connected Gmail accounts.
@Observable
@MainActor
final class AuthViewModel {
    var accounts: [GmailAccount] = []
    var isSigningIn = false
    var error: String?

    init() {
        accounts = AccountStore.shared.accounts
    }

    // MARK: - Sign In

    func signIn() async {
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }

        do {
            let window = NSApplication.shared.windows.first

            // 1. OAuth flow → tokens
            let token = try await OAuthService.shared.authorize(presentingWindow: window)

            // 2. Fetch user identity
            let userInfo = try await GmailProfileService.shared.getUserInfo(accessToken: token.accessToken)

            // 3. Save token to Keychain
            try TokenStore.shared.save(token, for: userInfo.email)

            // 4. Fetch Gmail profile (message counts)
            let profile = try await GmailProfileService.shared.getProfile(accountID: userInfo.email)

            // 5. Fetch signature (best-effort)
            let signature = try? await GmailProfileService.shared.getSignature(accountID: userInfo.email)

            // 6. Persist account metadata
            let account = GmailAccount(
                email:             userInfo.email,
                displayName:       userInfo.name ?? userInfo.email,
                profilePictureURL: userInfo.picture.flatMap { URL(string: $0) },
                messagesTotal:     profile.messagesTotal,
                threadsTotal:      profile.threadsTotal,
                signature:         signature,
                unreadCount:       0
            )
            AccountStore.shared.add(account)
            accounts = AccountStore.shared.accounts

        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Sign Out

    func signOut(_ account: GmailAccount) {
        // Retrieve the token synchronously before removal deletes it from the Keychain.
        let storedToken = try? TokenStore.shared.retrieve(for: account.id)

        // Revoke the OAuth token with Google (best-effort, non-blocking).
        // Prefer revoking the refresh token (also invalidates the access token);
        // fall back to the access token if no refresh token is stored.
        if let tokenToRevoke = storedToken?.refreshToken ?? storedToken?.accessToken {
            Task { await OAuthService.shared.revokeToken(token: tokenToRevoke) }
        }

        AccountStore.shared.remove(id: account.id)
        SubscriptionsStore.shared.deleteAccount(account.id)
        accounts = AccountStore.shared.accounts

        if accounts.isEmpty {
            UserDefaults.standard.set(false, forKey: UserDefaultsKey.isSignedIn)
        }
    }

    // MARK: - Helpers

    var primaryAccount: GmailAccount? { accounts.first }
    var hasAccounts: Bool { !accounts.isEmpty }
}
