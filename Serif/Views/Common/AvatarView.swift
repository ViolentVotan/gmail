import SwiftUI
import AppKit

struct AvatarView: View {
    let initials: String
    let color: String
    var size: CGFloat = 36
    var avatarURL: String? = nil
    var senderDomain: String? = nil

    @State private var image: NSImage? = nil
    @State private var lastLoadedURL: String?

    private var avatarTextColor: Color {
        let bgColor = NSColor(Color(hex: color)).usingColorSpace(.sRGB)
        let luminance = bgColor?.relativeLuminance() ?? 0
        return luminance > 0.7 ? .primary : .white
    }

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
                    .foregroundStyle(avatarTextColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(initials) avatar")
        .accessibilityAddTraits(.isImage)
        .task(id: avatarURL) {
            // Skip fetch entirely when the URL hasn't changed — image is already correct.
            guard avatarURL != lastLoadedURL else { return }
            image = nil

            // 1. Try primary URL (People API photo / Gravatar)
            if let url = avatarURL, let img = await AvatarCache.shared.image(for: url) {
                image = img
                lastLoadedURL = avatarURL
                return
            }

            // 2. Fallback: BIMI logo for org/brand domains
            if let domain = senderDomain,
               let bimiURL = await BIMIService.shared.logoURL(for: domain),
               let img = await AvatarCache.shared.image(for: bimiURL) {
                image = img
                lastLoadedURL = avatarURL
                return
            }

            lastLoadedURL = avatarURL
        }
    }
}
