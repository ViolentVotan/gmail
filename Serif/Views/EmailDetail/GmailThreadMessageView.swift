import SwiftUI

struct GmailThreadMessageView: View {
    let message: GmailMessage
    @Environment(\.theme) private var theme

    private var sender: Contact { GmailDataTransformer.parseContact(message.from) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(initials: sender.initials, color: sender.avatarColor, size: 32,
                           avatarURL: sender.avatarURL, senderDomain: sender.domain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(sender.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.textPrimary)

                    if let date = message.date {
                        Text(date.formattedRelative)
                            .font(.system(size: 11))
                            .foregroundColor(theme.textTertiary)
                    }
                }
            }

            Text(message.body.strippingHTML)
                .font(.system(size: 13))
                .foregroundColor(theme.textSecondary)
                .lineSpacing(4)
                .padding(.leading, 42)
        }
        .padding(16)
        .background(theme.cardBackground)
        .cornerRadius(10)
    }
}
