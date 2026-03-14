import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Binding var selectedFolder: Folder
    @Binding var selectedInboxCategory: InboxCategory?
    @Binding var selectedLabel: GmailLabel?
    @Binding var selectedAccountID: String?
    var authViewModel: AuthViewModel
    var categoryUnreadCounts: [InboxCategory: Int] = [:]
    var userLabels: [GmailLabel] = []
    var onRenameLabel: ((GmailLabel, String) -> Void)?
    var onDeleteLabel: ((GmailLabel) -> Void)?
    var onDropToTrash: ((String, String) -> Void)?
    var onDropToArchive: ((String, String) -> Void)?
    var onDropToSpam: ((String, String) -> Void)?
    var onDropToLabel: ((String, String, String) -> Void)?

    @Environment(SyncProgressManager.self) private var syncProgress

    @State private var labelToRename: GmailLabel?
    @State private var labelToDelete: GmailLabel?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            accountHeader
            sidebarList
        }
        .alert("Rename Label", isPresented: Binding(
            get: { labelToRename != nil },
            set: { if !$0 { labelToRename = nil } }
        )) {
            TextField("Label name", text: $renameText)
            Button("Cancel", role: .cancel) { labelToRename = nil }
            Button("Save") {
                if let label = labelToRename, !renameText.isEmpty {
                    onRenameLabel?(label, renameText)
                }
                labelToRename = nil
            }
        } message: {
            Text("Enter a new name for this label.")
        }
        .alert("Delete Label", isPresented: Binding(
            get: { labelToDelete != nil },
            set: { if !$0 { labelToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { labelToDelete = nil }
            Button("Delete", role: .destructive) {
                if let label = labelToDelete { onDeleteLabel?(label) }
                labelToDelete = nil
            }
        } message: {
            Text("Are you sure? This will remove the label from all messages.")
        }
    }

    // MARK: - Account Header

    private var accountHeader: some View {
        VStack(spacing: 0) {
            AccountSwitcherView(
                accounts: authViewModel.accounts,
                selectedAccountID: $selectedAccountID,
                isExpanded: true,
                onSignIn: { await authViewModel.signIn() },
                isSigningIn: authViewModel.isSigningIn
            ) { }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)

            if let account = authViewModel.accounts.first(where: { $0.id == selectedAccountID }) {
                Text(account.email)
                    .font(Typography.captionRegular)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Sidebar List

    private var sidebarList: some View {
        List {
            mailboxSection
            labelsSection
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .safeAreaInset(edge: .bottom) {
            SyncBubbleView(phase: syncProgress.phase)
                .padding(Spacing.sm)
                .opacity(syncProgress.isVisible ? 1 : 0)
                .frame(height: syncProgress.isVisible ? nil : 0, alignment: .bottom)
                .clipped()
                .animation(
                    syncProgress.isVisible ? SerifAnimation.springSnappy : SerifAnimation.springGentle,
                    value: syncProgress.isVisible
                )
        }
        .accessibilityRotor("Folders") {
            ForEach(Folder.allCases.filter { $0 != .labels }) { folder in
                AccessibilityRotorEntry(folder.rawValue, id: folder.id)
            }
        }
    }

    // MARK: - Mailbox Section

    private var mailboxSection: some View {
        Section("Mailbox") {
            ForEach(Folder.allCases.filter { $0 != .labels }) { folder in
                if folder == .inbox {
                    inboxDisclosureGroup(folder: folder)
                } else {
                    folderButton(folder: folder)
                }
            }
        }
    }

    private func inboxDisclosureGroup(folder: Folder) -> some View {
        DisclosureGroup {
            ForEach(InboxCategory.allCases) { category in
                Button {
                    selectedFolder = .inbox
                    selectedInboxCategory = category
                } label: {
                    Label {
                        Text(category.displayName)
                    } icon: {
                        Image(systemName: category.icon)
                            .frame(width: 20)
                    }
                }
                .badge(categoryUnreadCounts[category] ?? 0)
            }
        } label: {
            Button {
                selectedFolder = .inbox
                selectedInboxCategory = .all
            } label: {
                Label {
                    Text(folder.rawValue)
                } icon: {
                    Image(systemName: folder.icon)
                        .frame(width: 20)
                }
            }
        }
    }

    private func folderButton(folder: Folder) -> some View {
        Button {
            selectedFolder = folder
            selectedInboxCategory = nil
        } label: {
            Label {
                Text(folder.rawValue)
            } icon: {
                Image(systemName: folder.icon)
                    .frame(width: 20)
            }
        }
        .dropDestination(for: EmailDragItem.self) { items, _ in
            for item in items {
                for msgId in item.messageIds {
                    switch folder {
                    case .trash:
                        onDropToTrash?(msgId, item.accountID)
                    case .archive:
                        onDropToArchive?(msgId, item.accountID)
                    case .spam:
                        onDropToSpam?(msgId, item.accountID)
                    default: break
                    }
                }
            }
            return true
        }
    }

    // MARK: - Labels Section

    @ViewBuilder
    private var labelsSection: some View {
        if !userLabels.isEmpty {
            Section("Labels") {
                ForEach(userLabels) { label in
                    labelButton(label: label)
                }
            }
        }
    }

    private func labelButton(label: GmailLabel) -> some View {
        Button {
            selectedFolder = .labels
            selectedLabel = label
        } label: {
            Label {
                Text(label.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Circle()
                    .fill(Color(hex: label.color?.backgroundColor ?? "#888888"))
                    .frame(width: 10, height: 10)
                    .frame(width: 20)
            }
        }
        .dropDestination(for: EmailDragItem.self) { items, _ in
            for item in items {
                for msgId in item.messageIds {
                    onDropToLabel?(msgId, label.id, item.accountID)
                }
            }
            return true
        }
        .contextMenu {
            Button("Rename...") {
                labelToRename = label
                renameText = label.name
            }
            Button("Delete", role: .destructive) {
                labelToDelete = label
            }
        }
    }
}
