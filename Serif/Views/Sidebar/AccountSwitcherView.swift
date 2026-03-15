import SwiftUI

struct AccountSwitcherView: View {
    let accounts: [GmailAccount]
    @Binding var selectedAccountID: String?
    let isExpanded: Bool
    let onSignIn: () async -> Void
    let isSigningIn: Bool
    var onSignOut: ((GmailAccount) -> Void)?
    var onExpandSidebar: (() -> Void)?

    private var selectedAccount: GmailAccount? {
        accounts.first { $0.id == selectedAccountID } ?? accounts.first
    }

    var body: some View {
        HStack(spacing: isExpanded ? 6 : 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                let isActive = account.id == selectedAccountID
                || (selectedAccountID == nil && account.id == accounts.first?.id)
                let visible = isExpanded || isActive
                let activeIndex = accounts.firstIndex(where: { $0.id == (selectedAccountID ?? accounts.first?.id) }) ?? 0
                let distance = abs(index - activeIndex)
                let avatarSize: CGFloat = isActive && !isExpanded ? 34 : 28

                AccountAvatarBubble(
                    account: account,
                    isSelected: isActive,
                    size: avatarSize
                ) {
                    if isExpanded || !isActive {
                        selectedAccountID = account.id
                    } else {
                        onExpandSidebar?()
                    }
                }
                .contextMenu {
                    Text(account.email)
                    Divider()
                    if index != 0 {
                        Button("Set as Default") {
                            AccountStore.shared.setAsDefault(id: account.id)
                        }
                    }
                    Menu("Accent Color") {
                        ForEach(AccountStore.accentPalette, id: \.self) { hex in
                            Button {
                                AccountStore.shared.setAccentColor(id: account.id, hex: hex)
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
                    }
                    Divider()
                    Button("Sign Out", role: .destructive) {
                        onSignOut?(account)
                    }
                }
                .frame(width: visible ? avatarSize : 0, height: avatarSize)
                .opacity(visible ? 1 : 0)
                .zIndex(Double(accounts.count - distance))
            }
            addAccountButton(size: 28)
                .frame(width: isExpanded ? 28 : 0)
                .opacity(isExpanded ? 1 : 0)

            if isExpanded {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
    }

    private func addAccountButton(size: CGFloat) -> some View {
        Button {
            Task { await onSignIn() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .foregroundStyle(.secondary)
                Image(systemName: "plus")
                    .font(.system(size: size * 0.32, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isSigningIn ? 0.5 : 1)
        .disabled(isSigningIn)
        .help("Add account")
    }
}
