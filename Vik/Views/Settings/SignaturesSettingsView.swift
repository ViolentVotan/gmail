import SwiftUI

struct SignaturesSettingsView: View {
    let accountID: String
    var loadSendAs: (String) async throws -> [GmailSendAs]
    var onUpdateSignature: ((String, String, String) async throws -> GmailSendAs)?

    @State private var aliases: [GmailSendAs] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedAlias: GmailSendAs?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading signatures…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Typography.emptyStateIcon)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(Typography.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await fetchAliases() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if aliases.isEmpty {
                ContentUnavailableView(
                    "No Email Aliases",
                    systemImage: "at",
                    description: Text("No email aliases found for this account.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(aliases) { alias in
                    aliasRow(alias)
                }
                .listStyle(.inset)
            }
        }
        .task(id: accountID) { await fetchAliases() }
        .sheet(item: $selectedAlias) { alias in
            SignatureEditorView(
                alias: alias,
                accountID: accountID,
                onSave: { updated in
                    if let index = aliases.firstIndex(where: { $0.sendAsEmail == updated.sendAsEmail }) {
                        aliases[index] = updated
                    }
                },
                onUpdateSignature: onUpdateSignature
            )
        }
    }

    // MARK: - Alias Row

    private func aliasRow(_ alias: GmailSendAs) -> some View {
        Button {
            selectedAlias = alias
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.xsm) {
                        Text(alias.displayName ?? alias.sendAsEmail)
                            .font(Typography.callout)
                            .foregroundStyle(.primary)
                        if alias.isDefault == true {
                            Text("Default")
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.contrastingForeground(for: NSColor.controlAccentColor))
                                .padding(.horizontal, Spacing.xsm)
                                .padding(.vertical, Spacing.xxs)
                                .background(Capsule().fill(Color.accentColor))
                        }
                    }
                    Text(alias.sendAsEmail)
                        .font(Typography.footnote)
                        .foregroundStyle(.secondary)
                    if let sig = alias.signature, !sig.isEmpty {
                        Text(sig.strippingHTML)
                            .font(Typography.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("No signature")
                            .font(Typography.footnote)
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Typography.footnote)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Data Loading

    private func fetchAliases() async {
        isLoading = true
        errorMessage = nil
        do {
            aliases = try await loadSendAs(accountID)
        } catch {
            errorMessage = "Could not load signatures: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
