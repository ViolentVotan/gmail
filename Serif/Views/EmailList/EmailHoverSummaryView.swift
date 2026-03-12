import SwiftUI

struct EmailHoverSummaryView: View {
    let email: Email
    @State private var summaryVM = EmailSummaryViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                AvatarView(
                    initials: email.sender.initials,
                    color: email.sender.avatarColor,
                    size: 28,
                    avatarURL: email.sender.avatarURL,
                    senderDomain: email.sender.domain
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(email.sender.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(email.subject)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(email.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // Metadata pills
            if !email.recipients.isEmpty || email.hasAttachments {
                HStack(spacing: 6) {
                    if !email.recipients.isEmpty {
                        metadataPill(
                            icon: "person.2",
                            text: recipientsSummary
                        )
                    }
                    if email.hasAttachments {
                        metadataPill(
                            icon: "paperclip",
                            text: attachmentsSummary
                        )
                    }
                    if email.isFromMailingList {
                        metadataPill(icon: "newspaper", text: "Mailing list")
                    }
                }
            }

            Divider()
                .background(.separator)

            // Summary body
            if summaryVM.displayedText.isEmpty && summaryVM.isStreaming {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Summarizing...")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(summaryVM.displayedText)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeIn(duration: 0.05), value: summaryVM.displayedText)
            }

            // Footer
            if !summaryVM.isStreaming {
                footerView
            }
        }
        .padding(14)
        .onAppear { summaryVM.startStreaming(for: email) }
        .onDisappear { summaryVM.cancelStreaming() }
    }

    // MARK: - Metadata

    private var recipientsSummary: String {
        let names = email.recipients.prefix(3).map { $0.name.components(separatedBy: " ").first ?? $0.name }
        let count = email.recipients.count + email.cc.count
        if count <= 3 {
            return names.joined(separator: ", ")
        }
        return "\(names.prefix(2).joined(separator: ", ")) +\(count - 2)"
    }

    private var attachmentsSummary: String {
        let count = email.attachments.count
        if count == 0 { return "Attachments" }
        if count == 1, let first = email.attachments.first {
            return first.name
        }
        return "\(count) files"
    }

    private func metadataPill(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(.fill.quaternary))
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerView: some View {
        HStack {
            Spacer()
            if summaryVM.isAISummary, #available(macOS 26.0, *) {
                #if canImport(FoundationModels)
                Label("Apple Intelligence", systemImage: "apple.intelligence")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                #endif
            }
        }
    }

}
