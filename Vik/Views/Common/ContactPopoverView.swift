import SwiftUI

struct ContactPopoverView: View {
    @Bindable var viewModel: ContactPopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            infoSection
            Divider()
            actionsSection
        }
        .frame(minWidth: 280, maxWidth: 360)
        .task(id: viewModel.contact.email) {
            await viewModel.load()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: Spacing.md) {
            AvatarView(
                initials: viewModel.contact.initials,
                color: viewModel.contact.avatarColor,
                size: 48,
                avatarURL: viewModel.contact.avatarURL,
                senderDomain: viewModel.contact.domain
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.contact.name)
                    .font(Typography.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(viewModel.contact.email)
                    .font(Typography.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(Spacing.lg)
    }

    // MARK: - Info Rows

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if viewModel.isKnownContact {
                knownContactInfo
            } else {
                unknownSenderInfo
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    @ViewBuilder
    private var knownContactInfo: some View {
        if let org = viewModel.organization {
            infoRow(icon: "building.2", text: org)
        }
        if let phone = viewModel.phoneNumber {
            infoRow(icon: "phone", text: phone)
                .textSelection(.enabled)
        }
        if let location = viewModel.location {
            infoRow(icon: "mappin", text: location)
        }
        if viewModel.isEnriching {
            shimmerRow(width: 140)
            shimmerRow(width: 110)
        }
    }

    @ViewBuilder
    private var unknownSenderInfo: some View {
        if let domain = viewModel.sentByDomain {
            infoRow(icon: "globe", text: "sent by \(domain)")
        }
        if let encryption = viewModel.encryptionInfo {
            infoRow(
                icon: "lock.fill",
                text: encryption,
                iconColor: SemanticColor.success
            )
        }
        if let signed = viewModel.signedBy {
            infoRow(
                icon: "checkmark.shield",
                text: "signed by \(signed)",
                iconColor: SemanticColor.success
            )
        }
        if let mailed = viewModel.mailedBy {
            infoRow(
                icon: "envelope",
                text: "mailed by \(mailed)",
                iconColor: viewModel.isSuspiciousSender ? SemanticColor.error : nil
            )
        }
    }

    private func infoRow(icon: String, text: String, iconColor: Color? = nil) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(Typography.captionRegular)
                .foregroundStyle(iconColor ?? Color.secondary)
                .frame(width: 16, alignment: .center)
            Text(text)
                .font(Typography.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func shimmerRow(width: CGFloat) -> some View {
        HStack(spacing: Spacing.sm) {
            RoundedRectangle(cornerRadius: CornerRadius.xxs)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 16, height: 12)
            RoundedRectangle(cornerRadius: CornerRadius.xxs)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: width, height: 12)
        }
        .phaseAnimator([0.15, 0.3]) { content, phase in
            content.opacity(phase)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        GlassEffectContainer {
            FlowLayout(spacing: Spacing.sm) {
                Button { viewModel.copyEmail() } label: {
                    Label("Copy email", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Copy email address for \(viewModel.contact.name)")

                Button { viewModel.composeEmail() } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Compose email to \(viewModel.contact.name)")

                Button { viewModel.searchEmails() } label: {
                    Label("Search emails", systemImage: "magnifyingglass")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Search emails from \(viewModel.contact.name)")

                if viewModel.isKnownContact {
                    Button { viewModel.openContact() } label: {
                        Label("Open contact", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Open \(viewModel.contact.name) in Google Contacts")
                } else {
                    Button { viewModel.addToContacts() } label: {
                        Label("Add to contacts", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel("Add \(viewModel.contact.name) to contacts")
                }
            }
        }
        .padding(Spacing.lg)
    }
}
