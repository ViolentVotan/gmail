import SwiftUI
import AppKit

@Observable @MainActor
private final class AvatarLoader {
    var image: NSImage?

    func load(avatarURL: String?, senderDomain: String?) async {
        image = nil

        if let url = avatarURL, let img = await AvatarCache.shared.image(for: url) {
            image = img
            return
        }

        if let domain = senderDomain,
           let bimiURL = await BIMIService.shared.logoURL(for: domain),
           let img = await AvatarCache.shared.image(for: bimiURL) {
            image = img
        }
    }
}

struct AvatarView: View {
    let initials: String
    let color: String
    var size: CGFloat = 36
    var avatarURL: String? = nil
    var senderDomain: String? = nil

    @State private var loader = AvatarLoader()

    private static var textColorCache: [String: Color] = [:]

    private var avatarTextColor: Color {
        if let cached = Self.textColorCache[color] { return cached }
        let bgColor = NSColor(Color(hex: color)).usingColorSpace(.sRGB)
        let luminance = bgColor?.relativeLuminance() ?? 0
        let result: Color = luminance > 0.7 ? .primary : .white
        Self.textColorCache[color] = result
        return result
    }

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(hex: color).opacity(0.85))
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(avatarTextColor)
            }
        }
        .frame(width: size, height: size)
        .glassEffect(.regular, in: .circle)
        .accessibilityLabel("\(initials) avatar")
        .accessibilityAddTraits(.isImage)
        .task(id: avatarURL) {
            await loader.load(avatarURL: avatarURL, senderDomain: senderDomain)
        }
    }
}
