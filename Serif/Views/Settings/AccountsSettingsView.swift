import SwiftUI

struct AccountsSettingsView: View {
    @State private var accounts: [GmailAccount] = AccountStore.shared.accounts
    @State private var colorPickerAccountID: String?

    var body: some View {
        List {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                accountRow(account, index: index)
            }
            .onMove(perform: move)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .onAppear { refresh() }
        .overlay {
            if accounts.isEmpty {
                ContentUnavailableView(
                    "No Accounts",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Sign in from the main window to add accounts.")
                )
            }
        }
    }

    // MARK: - Account Row

    private func accountRow(_ account: GmailAccount, index: Int) -> some View {
        HStack(spacing: Spacing.sm) {
            avatar(for: account)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(account.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if index == 0 {
                        Text("Default")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: CornerRadius.xs))
                    }
                }

                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            accentColorButton(account)

            reorderButtons(index: index)
        }
        .padding(.vertical, 2)
        .contextMenu { contextMenu(for: account, index: index) }
    }

    // MARK: - Avatar

    @State private var avatarImages: [String: NSImage] = [:]

    private func avatar(for account: GmailAccount) -> some View {
        ZStack {
            Circle()
                .fill(.quaternary)

            if let image = avatarImages[account.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(String(account.displayName.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if let hex = account.accentColor {
                Circle()
                    .strokeBorder(Color(hex: hex), lineWidth: 2)
            }
        }
        .frame(width: 28, height: 28)
        .task(id: account.profilePictureURL?.absoluteString) {
            guard let url = account.profilePictureURL else { return }
            avatarImages[account.id] = await AvatarCache.shared.image(for: url.absoluteString)
        }
    }

    // MARK: - Accent Color

    private func accentColorButton(_ account: GmailAccount) -> some View {
        Menu {
            ForEach(AccountStore.accentPalette, id: \.self) { hex in
                Button {
                    AccountStore.shared.setAccentColor(id: account.id, hex: hex)
                    refresh()
                } label: {
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(Color(hex: hex))
                        Text(hex)
                        if account.accentColor == hex {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Circle()
                .fill(Color(hex: account.accentColor ?? "#888888"))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Change accent color")
    }

    // MARK: - Reorder Buttons

    private func reorderButtons(index: Int) -> some View {
        HStack(spacing: 2) {
            Button {
                guard index > 0 else { return }
                let id = accounts[index].id
                AccountStore.shared.moveUp(id: id)
                refresh()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move up")

            Button {
                guard index < accounts.count - 1 else { return }
                let id = accounts[index].id
                AccountStore.shared.moveDown(id: id)
                refresh()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(index == accounts.count - 1)
            .help("Move down")
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for account: GmailAccount, index: Int) -> some View {
        if index != 0 {
            Button("Set as Default") {
                AccountStore.shared.setAsDefault(id: account.id)
                refresh()
            }
            Divider()
        }

        Menu("Accent Color") {
            ForEach(AccountStore.accentPalette, id: \.self) { hex in
                Button {
                    AccountStore.shared.setAccentColor(id: account.id, hex: hex)
                    refresh()
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
    }

    // MARK: - Actions

    private func move(from source: IndexSet, to destination: Int) {
        AccountStore.shared.reorder(from: source, to: destination)
        refresh()
    }

    private func refresh() {
        accounts = AccountStore.shared.accounts
    }
}
