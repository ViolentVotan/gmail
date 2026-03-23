import SwiftUI

struct AccountSwitcherView: View {
    let accounts: [GmailAccount]
    @Binding var selectedAccountID: String?
    let isExpanded: Bool
    let onSignIn: () async -> Void
    let isSigningIn: Bool
    var onSignOut: ((GmailAccount) -> Void)?
    var onSetAsDefault: ((String) -> Void)?
    var onSetAccentColor: ((String, String) -> Void)?
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
                    AccountContextMenu(
                        account: account,
                        isDefault: index == 0,
                        onSetAsDefault: onSetAsDefault,
                        onSetAccentColor: onSetAccentColor,
                        onSignOut: onSignOut
                    )
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
        .padding(.horizontal, Spacing.lg)
    }

    private func addAccountButton(size: CGFloat) -> some View {
        Button {
            Task { await onSignIn() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .foregroundStyle(.secondary)
                if isSigningIn {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: size * 0.32, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isSigningIn ? OpacityToken.disabled : 1)
        .disabled(isSigningIn)
        .help("Add account")
        .accessibilityLabel("Add account")
    }
}
