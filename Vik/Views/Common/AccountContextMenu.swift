import SwiftUI

/// Shared context menu for account items — used in both the sidebar account switcher
/// and the accounts settings list for consistency.
struct AccountContextMenu: View {
    let account: GmailAccount
    let isDefault: Bool
    var onSetAsDefault: ((String) -> Void)?
    var onSetAccentColor: ((String, String) -> Void)?
    var onSignOut: ((GmailAccount) -> Void)?

    var body: some View {
        Text(account.email)

        Divider()

        if !isDefault {
            Button {
                onSetAsDefault?(account.id)
            } label: {
                Label("Set as Default", systemImage: "star")
            }
        }

        Menu {
            ForEach(AccountStore.accentPalette, id: \.self) { hex in
                Button {
                    onSetAccentColor?(account.id, hex)
                } label: {
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(Color(hex: hex))
                        if account.accentColor == hex {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label("Accent Color", systemImage: "paintpalette")
        }

        if onSignOut != nil {
            Divider()

            Button(role: .destructive) {
                onSignOut?(account)
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }
}
