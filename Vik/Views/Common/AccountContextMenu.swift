import SwiftUI

/// Shared context menu for account items — used in both the sidebar account switcher
/// and the accounts settings list for consistency.
private let accentColorNames: [String: String] = [
    "#FF6B6B": "Red",
    "#4ECDC4": "Teal",
    "#45B7D1": "Blue",
    "#F7DC6F": "Yellow",
    "#BB8FCE": "Purple",
    "#82E0AA": "Green",
    "#F0B27A": "Orange",
    "#85C1E9": "Sky",
]

struct AccountContextMenu: View {
    let account: GmailAccount
    let isDefault: Bool
    var onSetAsDefault: ((String) -> Void)?
    var onSetAccentColor: ((String, String) -> Void)?
    var onSignOut: ((GmailAccount) -> Void)?

    @State private var showSignOutConfirmation = false

    var body: some View {
        Group {
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
                            Text(accentColorNames[hex] ?? hex)
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
                    showSignOutConfirmation = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .confirmationDialog(
            "Sign out of \(account.email)?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                onSignOut?(account)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All local data for this account will be removed.")
        }
    }
}
