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

    private let avatarTextColor: Color

    init(initials: String, color: String, size: CGFloat = 36, avatarURL: String? = nil, senderDomain: String? = nil) {
        self.initials = initials
        self.color = color
        self.size = size
        self.avatarURL = avatarURL
        self.senderDomain = senderDomain

        let bgColor = NSColor(Color(hex: color)).usingColorSpace(.sRGB)
        let luminance = bgColor?.relativeLuminance() ?? 0
        self.avatarTextColor = luminance > 0.7 ? .primary : .white
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
