import SwiftUI

struct OriginalMessageView: View {
    let message: GmailMessage
    let rawSource: String?
    let isLoading: Bool

    @State private var copied = false

    // MARK: - Cached formatters (allocated once per type, not per render)

    private static let rfc2822Formatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss z"
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }()

    // MARK: - Parsed metadata

    private var messageIDValue: String {
        message.header(named: "Message-ID") ?? message.id
    }

    private var dateValue: String {
        if let d = message.date {
            return d.formattedLong
        }
        return message.header(named: "Date") ?? "—"
    }

    private var deliveryDelay: String? {
        guard let dateHeader = message.header(named: "Date"),
              let internalMs = message.internalDate,
              let ms = Int64(internalMs) else { return nil }
        // Use pre-allocated static formatters — avoid allocating DateFormatter on every render
        for formatter in Self.rfc2822Formatters {
            if let sent = formatter.date(from: dateHeader) {
                let received = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                let diff = Int(received.timeIntervalSince(sent))
                if diff < 0 { return nil }
                if diff < 60 { return "\(diff) seconds" }
                let mins = diff / 60
                let secs = diff % 60
                if mins < 60 { return secs > 0 ? "\(mins) min \(secs) sec" : "\(mins) min" }
                return "\(mins / 60)h \(mins % 60)m"
            }
        }
        return nil
    }

    private var fromValue: String { message.from }
    private var toValue: String { message.to }
    private var subjectValue: String { message.subject }

    private var spfValue: String? { extractAuthResult(for: "spf") }
    private var dkimValue: String? { extractAuthResult(for: "dkim") }
    private var dmarcValue: String? { extractAuthResult(for: "dmarc") }

    private func extractAuthResult(for method: String) -> String? {
        guard let results = message.header(named: "Authentication-Results") else { return nil }
        let parts = results.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix(method) {
                return trimmed
            }
        }
        return nil
    }

    private func authStatusColor(_ value: String?) -> Color {
        guard let v = value?.lowercased() else { return Color.secondary }
        if v.contains("=pass") { return .green }
        if v.contains("=fail") || v.contains("=softfail") { return .red }
        return .orange
    }

    private func authStatusLabel(_ value: String?) -> String {
        guard let v = value?.lowercased() else { return "—" }
        if v.contains("=pass") { return "PASS" }
        if v.contains("=fail") { return "FAIL" }
        if v.contains("=softfail") { return "SOFTFAIL" }
        if v.contains("=neutral") { return "NEUTRAL" }
        if v.contains("=none") { return "NONE" }
        return v
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metadataTable
                .padding(20)

            Divider().background(Color(.separatorColor))

            // Action buttons
            HStack(spacing: 16) {
                Button {
                    if let source = rawSource {
                        downloadOriginal(source)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.doc")
                            .font(Typography.captionRegular)
                        Text("Download Original")
                            .font(Typography.subhead)
                    }
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(rawSource == nil)

                Spacer()

                Button {
                    if let source = rawSource {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(source, forType: .string)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(Typography.captionRegular)
                        Text(copied ? "Copied!" : "Copy to Clipboard")
                            .font(Typography.subhead)
                    }
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(.rect(cornerRadius: CornerRadius.sm))
                }
                .buttonStyle(.plain)
                .disabled(rawSource == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider().background(Color(.separatorColor))

            // Raw source
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .tint(.gray)
                    Text("Loading original message…")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if let source = rawSource {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(source)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(20)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Could not load original message")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
    }

    // MARK: - Metadata table

    private var metadataTable: some View {
        VStack(spacing: 0) {
            metadataRow(label: "Message ID", value: messageIDValue)
            Divider().background(Color(.separatorColor))
            metadataRow(label: "Created at", value: dateValue + (deliveryDelay.map { " (\($0))" } ?? ""))
            Divider().background(Color(.separatorColor))
            metadataRow(label: "From", value: fromValue)
            Divider().background(Color(.separatorColor))
            metadataRow(label: "To", value: toValue)
            Divider().background(Color(.separatorColor))
            metadataRow(label: "Subject", value: subjectValue)
            Divider().background(Color(.separatorColor))
            authRow(label: "SPF", value: spfValue)
            Divider().background(Color(.separatorColor))
            authRow(label: "DKIM", value: dkimValue)
            Divider().background(Color(.separatorColor))
            authRow(label: "DMARC", value: dmarcValue)
        }
        .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm))
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.md).stroke(Color(.separatorColor), lineWidth: 1))
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(Typography.subhead)
                .foregroundStyle(.tertiary)
                .frame(width: 100, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.leading, 14)

            Text(value)
                .font(Typography.subheadRegular)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.vertical, 10)
                .padding(.trailing, 14)

            Spacer()
        }
    }

    private func authRow(label: String, value: String?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(Typography.subhead)
                .foregroundStyle(.tertiary)
                .frame(width: 100, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.leading, 14)

            HStack(spacing: 6) {
                Text(authStatusLabel(value))
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(authStatusColor(value))

                if let v = value {
                    Text(v)
                        .font(Typography.captionRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 10)
            .padding(.trailing, 14)

            Spacer()
        }
    }

    // MARK: - Download

    private func downloadOriginal(_ source: String) {
        guard let data = source.data(using: .utf8) else { return }
        FileUtils.saveWithPanel(data: data, suggestedName: "original_message.eml")
    }
}
