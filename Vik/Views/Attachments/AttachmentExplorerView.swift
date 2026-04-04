import SwiftUI
private import os

struct AttachmentExplorerView: View {
    private static let logger = Logger(category: "AttachmentExplorer")
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
        .task { await store.refresh() }
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
                    .font(Typography.titleLarge)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                HStack(spacing: Spacing.xsm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(store.stats.indexed)/\(store.stats.total) indexed")
                        .font(Typography.captionRegular)
                        .foregroundStyle(.tertiary)
                }
                .opacity(store.isIndexing ? 1 : 0)
            }

            SearchBarView(text: $store.searchQuery)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.md)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xsm) {
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
                    .padding(.horizontal, Spacing.xs)

                // Direction filters
                filterChip(label: "Received", isSelected: store.filterDirection == .received) {
                    store.filterDirection = store.filterDirection == .received ? nil : .received
                }
                filterChip(label: "Sent", isSelected: store.filterDirection == .sent) {
                    store.filterDirection = store.filterDirection == .sent ? nil : .sent
                }

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, Spacing.xs)

                rulesChip
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
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
                    .padding(Spacing.xl)
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
                Self.logger.error("Preview failed: \(error, privacy: .public)")
                ToastManager.shared.show(message: "Could not preview attachment", type: .error)
            }
        }
    }

    // MARK: - Rules Chip

    private var rulesChip: some View {
        Button { showRulesPopover.toggle() } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "eye.slash")
                    .font(Typography.captionSmallRegular)
                Text(store.exclusionRules.isEmpty ? "Rules" : "Rules (\(store.exclusionRules.count))")
                    .font(Typography.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .glassOrMaterial(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exclusion rules")
        .help("Manage exclusion rules")
        .popover(isPresented: $showRulesPopover, arrowEdge: .bottom) {
            rulesPopoverContent
        }
    }

    private var rulesPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exclusion Rules")
                .font(Typography.bodySemibold)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            if store.exclusionRules.isEmpty {
                Text("Right-click an attachment to add a rule")
                    .font(Typography.captionRegular)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: Spacing.xs) {
                    ForEach(store.exclusionRules, id: \.self) { rule in
                        HStack {
                            Text(rule)
                                .font(Typography.subheadMonospaced)
                                .foregroundStyle(.primary)
                            Spacer()
                            Button {
                                store.removeExclusionRule(rule)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(Typography.subheadRegular)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove exclusion rule")
                        }
                        .padding(.vertical, Spacing.xxs)
                    }
                }
            }

            Divider()

            HStack(spacing: Spacing.xsm) {
                TextField("Pattern (e.g. image-*)", text: $newRuleText)
                    .textFieldStyle(.plain)
                    .font(Typography.subheadRegular)
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
                        .font(Typography.callout)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add exclusion rule")
                .disabled(newRuleText.isEmpty)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 260)
    }

    // MARK: - Filter Chip

    private func filterChip(icon: String? = nil, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(Typography.captionSmallRegular)
                }
                Text(label)
                    .font(Typography.caption)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .contentShape(.rect)
            .modifier(FilterChipBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(label)
    }
}

private struct FilterChipBackground: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content.glassEffect(isSelected ? .regular.interactive() : .identity, in: .capsule)
    }
}
