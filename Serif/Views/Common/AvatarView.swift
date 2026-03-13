import SwiftUI
import AppKit

struct AvatarView: View {
    let initials: String
    let color: String
    var size: CGFloat = 36
    var avatarURL: String? = nil
    var senderDomain: String? = nil

    @State private var image: NSImage? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(hex: color))
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(initials) avatar")
        .accessibilityAddTraits(.isImage)
        .task(id: avatarURL) {
            image = nil

            // 1. Try primary URL (People API photo / Gravatar)
            if let url = avatarURL, let img = await AvatarCache.shared.image(for: url) {
                image = img
                return
            }

            // 2. Fallback: BIMI logo for org/brand domains
            if let domain = senderDomain,
               let bimiURL = await BIMIService.shared.logoURL(for: domain),
               let img = await AvatarCache.shared.image(for: bimiURL) {
                image = img
            }
        }
    }
}
