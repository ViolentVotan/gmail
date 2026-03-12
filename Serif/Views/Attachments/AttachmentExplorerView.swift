import SwiftUI

struct AttachmentExplorerView: View {
    @Bindable var store: AttachmentStore
    var panelCoordinator: PanelCoordinator
    let accountID: String
    var onViewMessage: ((String) -> Void)?
    var onDownloadAttachment: ((String, String, String) async throws -> Data)?
    @State private var downloadingAttachmentID: String?
    @State private var showExclusionRuleAlert = false
    @State private var exclusionRulePattern = ""
    @State private var showRulesPopover = false
    @State private var newRuleText = ""

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            content
        }
        .onAppear { store.refresh() }
        .alert("Add exclusion rule", isPresented: $showExclusionRuleAlert) {
            TextField("Pattern (e.g. Outlook-*)", text: $exclusionRulePattern)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                store.addExclusionRule(exclusionRulePattern)
            }
        } message: {
            Text("Attachments matching this pattern will be hidden. Use * as wildcard.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Attachments")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)

                Spacer()

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(store.stats.indexed)/\(store.stats.total) indexed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .opacity(store.isIndexing ? 1 : 0)
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

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)

                rulesChip
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
                                onTap: { loadAndPreview(result.attachment) },
                                onAddExclusionRule: { pattern in
                                    exclusionRulePattern = pattern
                                    showExclusionRuleAlert = true
                                },
                                onViewMessage: {
                                    onViewMessage?(result.attachment.messageId)
                                }
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
        ContentUnavailableView(
            store.searchQuery.isEmpty ? "No Attachments" : "No Results",
            systemImage: store.searchQuery.isEmpty ? "paperclip" : "magnifyingglass",
            description: Text(store.searchQuery.isEmpty ? "Attachments will appear here as emails are indexed" : "No results for \"\(store.searchQuery)\"")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load & Preview

    private func loadAndPreview(_ attachment: IndexedAttachment) {
        guard downloadingAttachmentID == nil else { return }
        downloadingAttachmentID = attachment.id
        let fileType = Attachment.FileType(rawValue: attachment.fileType) ?? .document
        panelCoordinator.previewAttachment(data: nil, name: attachment.filename, fileType: fileType)
        Task {
            defer { downloadingAttachmentID = nil }
            do {
                guard let data = try await onDownloadAttachment?(attachment.messageId, attachment.attachmentId, accountID) else { return }
                panelCoordinator.previewAttachment(data: data, name: attachment.filename, fileType: fileType)
            } catch {
                print("[AttachmentExplorer] Preview failed: \(error)")
            }
        }
    }

    // MARK: - Rules Chip

    private var rulesChip: some View {
        Button { showRulesPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                Text(store.exclusionRules.isEmpty ? "Rules" : "Rules (\(store.exclusionRules.count))")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showRulesPopover, arrowEdge: .bottom) {
            rulesPopoverContent
        }
    }

    private var rulesPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exclusion Rules")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)

            if store.exclusionRules.isEmpty {
                Text("Right-click an attachment to add a rule")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 4) {
                    ForEach(store.exclusionRules, id: \.self) { rule in
                        HStack {
                            Text(rule)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.primary)
                            Spacer()
                            Button {
                                store.removeExclusionRule(rule)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Divider()

            HStack(spacing: 6) {
                TextField("Pattern (e.g. image-*)", text: $newRuleText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .frame(minWidth: 140)
                    .onSubmit {
                        guard !newRuleText.isEmpty else { return }
                        store.addExclusionRule(newRuleText)
                        newRuleText = ""
                    }
                Button {
                    guard !newRuleText.isEmpty else { return }
                    store.addExclusionRule(newRuleText)
                    newRuleText = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(newRuleText.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    // MARK: - Filter Chip

    private func filterChip(icon: String? = nil, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial)))
        }
        .buttonStyle(.plain)
    }
}
