import SwiftUI

// MARK: - Behavior Settings Card

struct BehaviorSettingsCard: View {
    @Binding var undoDuration: Int
    @Binding var refreshInterval: Int
    let lastRefreshedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Behavior")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack {
                Text("Undo duration")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $undoDuration) {
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                    Text("20s").tag(20)
                    Text("30s").tag(30)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
            }

            Divider()

            HStack {
                Text("Refresh interval")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $refreshInterval) {
                    Text("2 min").tag(120)
                    Text("5 min").tag(300)
                    Text("10 min").tag(600)
                    Text("1 hour").tag(3600)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
            }

            RefreshStatusView(lastRefreshedAt: lastRefreshedAt, refreshInterval: refreshInterval)
        }
        .cardStyle()
    }
}

// MARK: - Contacts Settings Card

struct ContactsSettingsCard: View {
    let accountID: String
    var onRefreshContacts: ((String) async -> Void)?
    @State private var isRefreshingContacts = false
    @State private var contactCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Contacts")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack {
                Text("\(contactCount) contacts cached")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    guard !isRefreshingContacts else { return }
                    isRefreshingContacts = true
                    Task {
                        await onRefreshContacts?(accountID)
                        isRefreshingContacts = false
                        contactCount = ContactStore.shared.contacts(for: accountID).count
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isRefreshingContacts {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.footnote)
                        }
                        Text(isRefreshingContacts ? "Refreshing…" : "Refresh")
                            .font(.callout)
                    }
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshingContacts)
            }
        }
        .cardStyle()
        .onAppear {
            contactCount = ContactStore.shared.contacts(for: accountID).count
        }
    }
}

// MARK: - Signature Settings Card

struct SignatureSettingsCard: View {
    let aliases: [GmailSendAs]
    let accountID: String
    @Binding var signatureForNew: String
    @Binding var signatureForReply: String
    var onAliasesUpdated: (() -> Void)?
    var onSaveSignature: ((String, String, String) async throws -> GmailSendAs)?
    @State private var editingAlias: GmailSendAs?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signatures")
                .font(.headline)
                .foregroundStyle(.primary)

            if aliases.isEmpty {
                Text("No aliases found")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(aliases, id: \.sendAsEmail) { alias in
                        Button {
                            editingAlias = alias
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(alias.displayName ?? alias.sendAsEmail)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                    if alias.isPrimary == true {
                                        Text("Primary")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.tint)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                    }
                                    Spacer()
                                    Image(systemName: "pencil")
                                        .font(.footnote)
                                        .foregroundStyle(.tertiary)
                                }
                                Text(alias.sendAsEmail)
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                if let sig = alias.signature, !sig.isEmpty {
                                    Text(sig.strippingHTML.prefix(80) + (sig.strippingHTML.count > 80 ? "…" : ""))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                } else {
                                    Text("No signature")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .italic()
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                HStack {
                    Text("New emails")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $signatureForNew) {
                        Text("Default").tag("")
                        ForEach(aliases, id: \.sendAsEmail) { alias in
                            Text(alias.displayName ?? alias.sendAsEmail).tag(alias.sendAsEmail)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }

                HStack {
                    Text("Replies & forwards")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $signatureForReply) {
                        Text("Default").tag("")
                        ForEach(aliases, id: \.sendAsEmail) { alias in
                            Text(alias.displayName ?? alias.sendAsEmail).tag(alias.sendAsEmail)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
            }
        }
        .cardStyle()
        .sheet(item: $editingAlias) { alias in
            SignatureEditorView(
                alias: alias,
                accountID: accountID,
                onSave: { _ in onAliasesUpdated?() },
                onUpdateSignature: onSaveSignature
            )
        }
    }
}

// MARK: - Storage Settings Card

struct StorageSettingsCard: View {
    var attachmentStore: AttachmentStore
    @AppStorage("attachmentScanMonths") private var scanMonths: Int = -1 // UserDefaultsKey.attachmentScanMonths
    @State private var dbSize: Int64 = 0
    @State private var showClearConfirm = false
    @State private var isClearing = false

    private var formattedSize: String {
        GmailDataTransformer.sizeString(dbSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack {
                Text("Attachment scan depth")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $scanMonths) {
                    Text("6 months").tag(6)
                    Text("1 year").tag(12)
                    Text("2 years").tag(24)
                    Text("4 years").tag(48)
                    Text("All time").tag(-1)
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attachment index")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(formattedSize)
                            .font(.footnote.monospaced().weight(.medium))
                            .foregroundStyle(.primary)
                        Text("\(attachmentStore.stats.total) attachments")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button {
                    showClearConfirm = true
                } label: {
                    HStack(spacing: 5) {
                        if isClearing {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "trash")
                                .font(.footnote)
                        }
                        Text(isClearing ? "Clearing..." : "Clear")
                            .font(.callout)
                    }
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .disabled(isClearing || dbSize == 0)
            }
        }
        .cardStyle()
        .onAppear {
            attachmentStore.refresh()
            dbSize = AttachmentDatabase.shared.databaseSizeBytes()
        }
        .onChange(of: attachmentStore.stats.total) { _, _ in
            dbSize = AttachmentDatabase.shared.databaseSizeBytes()
        }
        .alert("Clear attachment index?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                isClearing = true
                AttachmentDatabase.shared.clearAll()
                attachmentStore.refresh()
                dbSize = AttachmentDatabase.shared.databaseSizeBytes()
                isClearing = false
            }
        } message: {
            Text("This will delete all cached data (\(formattedSize)). Attachments will be re-indexed as you browse your emails.")
        }
    }
}

// MARK: - Apple Intelligence Settings

struct AppleIntelligenceSettingsCard: View {
    @AppStorage("aiLabelSuggestions") private var labelSuggestions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Intelligence")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Label suggestions")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("Suggest labels for emails using on-device AI")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("", isOn: $labelSuggestions)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - Developer Settings

struct DeveloperSettingsCard: View {
    @AppStorage("showDebugMenu") private var showDebugMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Developer")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack {
                Text("Show Debug menu")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $showDebugMenu)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - Refresh Status

struct RefreshStatusView: View {
    let lastRefreshedAt: Date?
    let refreshInterval: Int
    @State private var now: Date = Date()

    private var timer: Timer.TimerPublisher {
        Timer.publish(every: 1, on: .main, in: .common)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(lastRefreshLabel)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            HStack {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(nextRefreshLabel)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .onReceive(timer.autoconnect()) { date in now = date }
    }

    private var lastRefreshLabel: String {
        guard let last = lastRefreshedAt else { return "Last refresh: never" }
        let elapsed = Int(now.timeIntervalSince(last))
        if elapsed < 60 { return "Last refresh: \(elapsed)s ago" }
        let mins = elapsed / 60
        return "Last refresh: \(mins) min ago"
    }

    private var nextRefreshLabel: String {
        guard let last = lastRefreshedAt else { return "Next refresh: soon" }
        let elapsed = now.timeIntervalSince(last)
        let remaining = max(0, Double(refreshInterval) - elapsed)
        let secs = Int(remaining)
        if secs < 60 { return "Next refresh: in \(secs)s" }
        let mins = secs / 60
        let rem  = secs % 60
        return rem > 0 ? "Next refresh: in \(mins)m \(rem)s" : "Next refresh: in \(mins)m"
    }
}
