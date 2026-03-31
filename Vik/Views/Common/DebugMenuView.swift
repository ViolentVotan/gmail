import SwiftUI

/// File-private VM that wraps AttachmentDatabase calls so the view
/// doesn't reference the service singleton directly.
@Observable @MainActor
private final class DebugViewModel {
    private(set) var indexingStats = IndexingStats()
    private(set) var unsupportedTypes: [(mimeType: String, count: Int)] = []

    func refreshIndexingStats(accountID: String) async {
        let raw = await AttachmentDatabase.shared.stats(accountID: accountID)
        indexingStats = IndexingStats(
            total: raw.total,
            indexed: raw.indexed,
            pending: raw.pending,
            failed: raw.failed
        )
        unsupportedTypes = await AttachmentDatabase.shared.unsupportedMimeTypes(accountID: accountID)
    }
}

struct DebugMenuView: View {
    let accountID: String

    @AppStorage("isSignedIn") private var isSignedIn: Bool = false
    private let logger = APILogger.shared
    @State private var viewModel = DebugViewModel()
    @State private var expandedEntryID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // MARK: - Attachment Indexer
            debugSection(title: "Attachment Indexer") {
                VStack(alignment: .leading, spacing: 6) {
                    indexerStatRow("Total", value: viewModel.indexingStats.total, color: .primary)
                    indexerStatRow("Indexed", value: viewModel.indexingStats.indexed, color: .secondary)
                    indexerStatRow("Pending", value: viewModel.indexingStats.pending, color: .blue)
                    indexerStatRow("Failed", value: viewModel.indexingStats.failed, color: .red)

                    if viewModel.indexingStats.total > 0 {
                        let progress = viewModel.indexingStats.total > 0
                            ? Double(viewModel.indexingStats.indexed) / Double(viewModel.indexingStats.total)
                            : 0
                        ProgressView(value: progress)
                            .tint(.accentColor)
                            .padding(.top, Spacing.xs)
                            .padding(.horizontal, Spacing.md)
                    }

                    if !viewModel.unsupportedTypes.isEmpty {
                        Divider().padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
                        Text("Unsupported MIME types")
                            .font(Typography.captionSmall)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Spacing.md)
                        ForEach(viewModel.unsupportedTypes, id: \.mimeType) { entry in
                            HStack {
                                Text(entry.mimeType)
                                    .font(Typography.captionMonospaced)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("×\(entry.count)")
                                    .font(.caption.weight(.medium).monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Spacing.md)
                        }
                    }
                }
                .padding(.vertical, Spacing.xs)

                debugButton(icon: "arrow.clockwise", label: "Refresh Stats") {
                    Task { await viewModel.refreshIndexingStats(accountID: accountID) }
                }
            }

            // MARK: - Onboarding
            debugSection(title: "Onboarding") {
                debugButton(icon: "arrow.counterclockwise", label: "Show Onboarding") {
                    isSignedIn = false
                }
            }

            // MARK: - API Request Log
            debugSection(title: "API Request Log (\(logger.entries.count))") {
                if logger.entries.isEmpty {
                    Text("No requests yet")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(logger.entries) { entry in
                            logEntryRow(entry)
                            if entry.id != logger.entries.last?.id {
                                Divider()
                            }
                        }
                    }
                    .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm))
                }

                debugButton(icon: "trash", label: "Clear Log") {
                    logger.clear()
                    expandedEntryID = nil
                }
            }

        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await viewModel.refreshIndexingStats(accountID: accountID)
        }
    }

    // MARK: - Indexer Stats

    private func indexerStatRow(_ label: String, value: Int, color: Color) -> some View {
        HStack {
            Text(label)
                .font(Typography.subheadRegular)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(value)")
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(color)
        }
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Log Entry Row

    @ViewBuilder
    private func logEntryRow(_ entry: APILogEntry) -> some View {
        let isExpanded = expandedEntryID == entry.id
        VStack(alignment: .leading, spacing: 0) {

            // ── Collapsed header ──
            Button {
                withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                    expandedEntryID = isExpanded ? nil : entry.id
                }
            } label: {
                HStack(spacing: 6) {
                    let badgeBackground = entry.fromCache ? Color.secondary : (entry.method == "GET" ? BrandColor.blueText : SemanticColor.warning)
                    Text(entry.fromCache ? "CACHE" : entry.method)
                        .font(.caption2.weight(.bold).monospaced())
                        .foregroundStyle(Color.contrastingForeground(for: NSColor(badgeBackground)))
                        .padding(.horizontal, 5)
                        .padding(.vertical, Spacing.xxs)
                        .background(badgeBackground)
                        .clipShape(.rect(cornerRadius: CornerRadius.xs))

                    Text(entry.shortPath)
                        .font(Typography.captionMonospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if !entry.fromCache {
                        Text("\(entry.durationMs)ms")
                            .font(Typography.captionSmallRegular)
                            .foregroundStyle(.tertiary)
                    }

                    Text(entry.statusLabel)
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(statusColor(for: entry.statusLevel))
                        .frame(width: 40, alignment: .trailing)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(Typography.captionSmallRegular)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── Expanded detail ──
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {

                    // REQUEST block
                    detailSectionLabel("REQUEST")

                    monoBlock {
                        Text("\(entry.method) \(entry.path)")
                            .foregroundStyle(.primary)
                    }

                    if !entry.requestHeaders.isEmpty {
                        monoBlock {
                            ForEach(entry.requestHeaders.keys.sorted(), id: \.self) { key in
                                HStack(alignment: .top, spacing: 0) {
                                    Text(key + ": ")
                                        .foregroundStyle(.tertiary)
                                    Text(entry.requestHeaders[key] ?? "")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let reqBody = entry.requestBody, !reqBody.isEmpty {
                        detailSectionLabel("REQUEST BODY")
                        scrollableMonoBlock(reqBody, maxHeight: 120)
                    }

                    // RESPONSE block
                    HStack {
                        detailSectionLabel("RESPONSE")
                        if let err = entry.errorMessage {
                            Text(err)
                                .font(Typography.captionSmall)
                                .foregroundStyle(SemanticColor.error)
                        }
                        Spacer()
                        Text("\(entry.responseSize) bytes · \(entry.date.formatted(.dateTime.hour().minute().second()))")
                            .font(Typography.captionSmallRegular)
                            .foregroundStyle(.tertiary)
                    }

                    if !entry.responseHeaders.isEmpty {
                        monoBlock {
                            ForEach(entry.responseHeaders.keys.sorted(), id: \.self) { key in
                                HStack(alignment: .top, spacing: 0) {
                                    Text(key + ": ")
                                        .foregroundStyle(.tertiary)
                                    Text(entry.responseHeaders[key] ?? "")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !entry.responseBody.isEmpty {
                        HStack {
                            if entry.bodyTruncated {
                                Text("Body truncated at 200 KB")
                                    .font(Typography.captionSmallRegular)
                                    .foregroundStyle(SemanticColor.warning)
                            }
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.responseBody, forType: .string)
                            } label: {
                                Label("Copy body", systemImage: "doc.on.doc")
                                    .font(Typography.captionSmallRegular)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, Spacing.xs)

                        scrollableMonoBlock(entry.responseBody, maxHeight: 360)
                    }
                }
                .padding(.bottom, Spacing.sm)
                .background(.opacity(0.6))
            }
        }
    }

    // MARK: - Sub-components

    private func detailSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(.tertiary)
            .tracking(1)
            .padding(.horizontal, 10)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xxs)
    }

    private func monoBlock<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            content()
        }
        .font(.caption2.monospaced())
        .textSelection(.enabled)
        .padding(.horizontal, 10)
        .padding(.vertical, Spacing.xs)
    }

    private func scrollableMonoBlock(_ text: String, maxHeight: CGFloat) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.sm)
        }
        .frame(maxHeight: maxHeight)
        .clipShape(.rect(cornerRadius: CornerRadius.xs))
        .padding(.horizontal, 10)
        .padding(.bottom, Spacing.xs)
    }

    // MARK: - Helpers

    private func debugSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typography.captionSemibold)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }

    private func statusColor(for level: APILogEntry.StatusLevel) -> Color {
        switch level {
        case .success: return .secondary
        case .cached:  return .secondary
        case .warning: return SemanticColor.warning
        case .error:   return SemanticColor.error
        }
    }

    private func debugButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(Typography.body)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(label)
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm), interactive: true)
        }
        .buttonStyle(.plain)
    }
}
