import SwiftUI

struct AttachmentExplorerView: View {
    @ObservedObject var store: AttachmentStore
    @ObservedObject var panelCoordinator: PanelCoordinator
    let accountID: String
    @State private var downloadingAttachmentID: String?
    @Environment(\.theme) private var theme

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.divider)
            filterBar
            content
        }
        .background(theme.listBackground)
        .onAppear { store.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Attachments")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(theme.textPrimary)

                Spacer()

                if store.isIndexing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(theme.textTertiary)
                        Text("\(store.stats.indexed)/\(store.stats.total) indexed")
                            .font(.system(size: 11))
                            .foregroundColor(theme.textTertiary)
                    }
                }
            }

            SearchBarView(text: $store.searchQuery)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // "All" file type chip
                filterChip(label: "All", isSelected: store.filterFileType == nil) {
                    store.filterFileType = nil
                }

                // Each file type
                ForEach(Attachment.FileType.allCases, id: \.self) { fileType in
                    filterChip(
                        icon: fileType.rawValue,
                        label: fileType.label,
                        isSelected: store.filterFileType == fileType
                    ) {
                        store.filterFileType = store.filterFileType == fileType ? nil : fileType
                    }
                }

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)

                // Direction filters
                filterChip(label: "Received", isSelected: store.filterDirection == .received) {
                    store.filterDirection = store.filterDirection == .received ? nil : .received
                }
                filterChip(label: "Sent", isSelected: store.filterDirection == .sent) {
                    store.filterDirection = store.filterDirection == .sent ? nil : .sent
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Content

    private var content: some View {
        Group {
            if store.displayedAttachments.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.displayedAttachments) { result in
                            AttachmentCardView(
                                result: result,
                                isSearchActive: !store.searchQuery.isEmpty,
                                accountID: accountID,
                                onTap: { loadAndPreview(result.attachment) }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: store.searchQuery.isEmpty ? "paperclip" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(theme.textTertiary)
            Text(store.searchQuery.isEmpty ? "No attachments" : "No results for \"\(store.searchQuery)\"")
                .font(.system(size: 13))
                .foregroundColor(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load & Preview

    private func loadAndPreview(_ attachment: IndexedAttachment) {
        guard downloadingAttachmentID == nil else { return }
        downloadingAttachmentID = attachment.id
        Task {
            defer { downloadingAttachmentID = nil }
            do {
                let data = try await GmailMessageService.shared.getAttachment(
                    messageID: attachment.messageId,
                    attachmentID: attachment.attachmentId,
                    accountID: accountID
                )
                let fileType = Attachment.FileType(rawValue: attachment.fileType) ?? .document
                await MainActor.run {
                    panelCoordinator.previewAttachment(data: data, name: attachment.filename, fileType: fileType)
                }
            } catch {
                print("[AttachmentExplorer] Preview failed: \(error)")
            }
        }
    }

    // MARK: - Filter Chip

    private func filterChip(icon: String? = nil, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isSelected ? theme.textInverse : theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? theme.accentPrimary : theme.cardBackground))
        }
        .buttonStyle(.plain)
    }
}
