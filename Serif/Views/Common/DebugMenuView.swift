import SwiftUI

struct DebugMenuView: View {
    let accountID: String

    init(accountID: String) {
        self.accountID = accountID
    }

    @AppStorage("isSignedIn") private var isSignedIn: Bool = false
    private let logger = APILogger.shared
    @State private var expandedEntryID: UUID?
    @State private var indexingStats = IndexingStats()
    @State private var unsupportedTypes: [(mimeType: String, count: Int)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // MARK: - Attachment Indexer
            debugSection(title: "Attachment Indexer") {
                VStack(alignment: .leading, spacing: 6) {
                    indexerStatRow("Total", value: indexingStats.total, color: .primary)
                    indexerStatRow("Indexed", value: indexingStats.indexed, color: .secondary)
                    indexerStatRow("Pending", value: indexingStats.pending, color: .blue)
                    indexerStatRow("Failed", value: indexingStats.failed, color: .red)

                    if indexingStats.total > 0 {
                        let progress = indexingStats.total > 0
                            ? Double(indexingStats.indexed) / Double(indexingStats.total)
                            : 0
                        ProgressView(value: progress)
                            .tint(.accentColor)
                            .padding(.top, 4)
                            .padding(.horizontal, 12)
                    }

                    if !unsupportedTypes.isEmpty {
                        Divider().padding(.horizontal, 12).padding(.vertical, 4)
                        Text("Unsupported MIME types")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                        ForEach(unsupportedTypes, id: \.mimeType) { entry in
                            HStack {
                                Text(entry.mimeType)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("×\(entry.count)")
                                    .font(.caption.weight(.medium).monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.vertical, 4)

                debugButton(icon: "arrow.clockwise", label: "Refresh Stats") {
                    Task { await refreshIndexingStats() }
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
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(logger.entries.reversed()) { entry in
                            logEntryRow(entry)
                            if entry.id != logger.entries.first?.id {
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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await refreshIndexingStats()
        }
    }

    // MARK: - Indexer Stats

    private func indexerStatRow(_ label: String, value: Int, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(value)")
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
    }

    private func refreshIndexingStats() async {
        let raw = await AttachmentDatabase.shared.stats(accountID: accountID)
        indexingStats = IndexingStats(
            total: raw.total,
            indexed: raw.indexed,
            pending: raw.pending,
            failed: raw.failed
        )
        unsupportedTypes = await AttachmentDatabase.shared.unsupportedMimeTypes(accountID: accountID)
    }

    // MARK: - Log Entry Row

    @ViewBuilder
    private func logEntryRow(_ entry: APILogEntry) -> some View {
        let isExpanded = expandedEntryID == entry.id
        VStack(alignment: .leading, spacing: 0) {

            // ── Collapsed header ──
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedEntryID = isExpanded ? nil : entry.id
                }
            } label: {
                HStack(spacing: 6) {
                    Text(entry.fromCache ? "CACHE" : entry.method)
                        .font(.caption2.weight(.bold).monospaced())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(entry.fromCache ? Color.gray : (entry.method == "GET" ? Color.blue : Color.orange))
                        .clipShape(.rect(cornerRadius: CornerRadius.xs))

                    Text(entry.shortPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if !entry.fromCache {
                        Text("\(entry.durationMs)ms")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text(entry.statusLabel)
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(statusColor(for: entry.statusLevel))
                        .frame(width: 40, alignment: .trailing)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
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
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        Text("\(entry.responseSize) bytes · \(entry.date.formatted(.dateTime.hour().minute().second()))")
                            .font(.caption2)
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
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.responseBody, forType: .string)
                            } label: {
                                Label("Copy body", systemImage: "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 4)

                        scrollableMonoBlock(entry.responseBody, maxHeight: 360)
                    }
                }
                .padding(.bottom, 8)
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
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func monoBlock<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            content()
        }
        .font(.caption2.monospaced())
        .textSelection(.enabled)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func scrollableMonoBlock(_ text: String, maxHeight: CGFloat) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: maxHeight)
        .clipShape(.rect(cornerRadius: CornerRadius.xs))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Helpers

    private func debugSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }

    private func statusColor(for level: APILogEntry.StatusLevel) -> Color {
        switch level {
        case .success: return .secondary
        case .cached:  return .gray
        case .warning: return .blue
        case .error:   return .red
        }
    }

    private func debugButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(label)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm), interactive: true)
        }
        .buttonStyle(.plain)
    }
}
