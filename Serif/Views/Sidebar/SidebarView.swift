import SwiftUI

struct SidebarView: View {
    @Binding var selectedFolder: Folder
    @Binding var selectedInboxCategory: InboxCategory?
    @Binding var selectedLabel: GmailLabel?
    @Binding var selectedAccountID: String?
    @Binding var showSettings: Bool
    @Binding var isExpanded: Bool
    @Binding var showHelp: Bool
    @Binding var showDebug: Bool
    @ObservedObject var authViewModel: AuthViewModel
    var categoryUnreadCounts: [InboxCategory: Int] = [:]
    var userLabels: [GmailLabel] = []
    @Environment(\.theme) private var theme

    @State private var inboxExpanded = true
    @State private var labelsExpanded = false

    private var sidebarWidth: CGFloat { isExpanded ? 200 : 60 }

    var body: some View {
        VStack(spacing: 0) {
            // Logo
            if isExpanded {
                HStack {
                    Image("SerifLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 12)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 16)
                Spacer()
                    .frame(height: 10)
            } else {
                Spacer().frame(height: 52)
            }

            // Account switcher
            AccountSwitcherView(
                accounts: authViewModel.accounts,
                selectedAccountID: $selectedAccountID,
                isExpanded: isExpanded,
                onSignIn: { await authViewModel.signIn() },
                isSigningIn: authViewModel.isSigningIn
            )
            .padding(.bottom, isExpanded ? 12 : 8)

            // Divider
            if isExpanded {
                Rectangle()
                    .fill(theme.sidebarTextMuted.opacity(0.3))
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            // Folder navigation
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Folder.allCases) { folder in
                        if folder == .inbox {
                            inboxSection
                        } else if folder == .labels {
                            labelsSection
                        } else {
                            SidebarItemView(
                                folder: folder,
                                isSelected: selectedFolder == folder,
                                isExpanded: isExpanded
                            ) {
                                selectedFolder = folder
                                selectedInboxCategory = nil
                            }
                        }
                    }
                }
                .padding(.horizontal, isExpanded ? 8 : 0)
            }

            // Bottom actions
            VStack(spacing: 2) {
                #if DEBUG
                sidebarButton(icon: "ladybug.fill", label: "Debug") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showDebug = true }
                }
                #endif
                sidebarButton(icon: "gearshape.fill", label: "Settings") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showSettings = true }
                }
                sidebarButton(icon: "questionmark.circle", label: "Help") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showHelp = true }
                }
            }
            .padding(.horizontal, isExpanded ? 8 : 0)
            .padding(.bottom, 16)
        }
        .frame(width: sidebarWidth)
        .background(theme.sidebarBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    // MARK: - Inbox super-category

    private var inboxSection: some View {
        VStack(spacing: 2) {
            InboxParentRow(
                isSelected: selectedFolder == .inbox,
                isExpanded: isExpanded,
                inboxExpanded: $inboxExpanded,
                theme: theme
            ) {
                selectedFolder = .inbox
                selectedInboxCategory = .all
                withAnimation(.easeInOut(duration: 0.2)) { inboxExpanded.toggle() }
            }

            if isExpanded && inboxExpanded {
                ForEach(InboxCategory.allCases) { category in
                    InboxCategoryRow(
                        category: category,
                        isSelected: selectedFolder == .inbox && selectedInboxCategory == category,
                        unreadCount: categoryUnreadCounts[category] ?? 0,
                        theme: theme
                    ) {
                        selectedFolder = .inbox
                        selectedInboxCategory = category
                    }
                }
            }
        }
    }

    // MARK: - Labels section

    private var labelsSection: some View {
        VStack(spacing: 2) {
            LabelsParentRow(
                isSelected: selectedFolder == .labels,
                isExpanded: isExpanded,
                labelsExpanded: $labelsExpanded,
                theme: theme
            ) {
                selectedFolder = .labels
                if let first = userLabels.first, selectedLabel == nil {
                    selectedLabel = first
                }
                withAnimation(.easeInOut(duration: 0.2)) { labelsExpanded.toggle() }
            }

            if isExpanded && labelsExpanded {
                ForEach(userLabels) { label in
                    LabelSidebarRow(
                        label: label,
                        isSelected: selectedFolder == .labels && selectedLabel?.id == label.id,
                        theme: theme
                    ) {
                        selectedFolder = .labels
                        selectedLabel = label
                    }
                }
            }
        }
    }

    // MARK: - Generic bottom button

    private func sidebarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isExpanded {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundColor(theme.sidebarTextMuted)
                        .frame(width: 20)
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundColor(theme.sidebarTextMuted)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            } else {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(theme.sidebarTextMuted)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}
