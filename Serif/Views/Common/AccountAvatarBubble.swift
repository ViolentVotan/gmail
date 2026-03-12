import SwiftUI
import AppKit

struct AccountAvatarBubble: View {
    let account: GmailAccount
    let isSelected: Bool
    var size: CGFloat = 34
    let action: () -> Void
    @State private var image: NSImage?

    private var initial: String {
        String(account.displayName.prefix(1)).uppercased()
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Base circle
                Circle().fill(isSelected ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.quaternary))
                if !isSelected && image == nil && account.profilePictureURL == nil {
                    Circle().strokeBorder(.separator, lineWidth: 1)
                }

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                } else {
                    Text(initial)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }

                // Accent color ring when selected
                if isSelected, let hex = account.accentColor {
                    Circle().strokeBorder(Color(hex: hex), lineWidth: 2.5)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .drawingGroup(opaque: false)
        }
        .buttonStyle(.plain)
        .help(account.email)
        .task(id: account.profilePictureURL?.absoluteString) {
            guard let url = account.profilePictureURL else { return }
            image = await AvatarCache.shared.image(for: url.absoluteString)
        }
    }
}
