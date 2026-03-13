import SwiftUI

// MARK: - Spacing

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

enum ButtonSize {
    static let sm: CGFloat = 26
    static let md: CGFloat = 28
    static let lg: CGFloat = 30
}

// MARK: - Corner Radius

enum CornerRadius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

// MARK: - Animation

enum SerifAnimation {
    static let springDefault = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let springSnappy = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let springGentle = Animation.spring(response: 0.4, dampingFraction: 0.9)
}

// MARK: - Typography

enum Typography {
    // Display
    static let titleLarge: Font = .title2.bold()

    // Title
    static let title: Font = .title3.bold()
    static let titleSemibold: Font = .title3.weight(.semibold)

    // Headline
    static let headline: Font = .headline
    static let headlineSemibold: Font = .headline.weight(.semibold)

    // Subhead
    static let subhead: Font = .subheadline.weight(.medium)
    static let subheadRegular: Font = .subheadline
    static let subheadSemibold: Font = .subheadline.weight(.semibold)

    // Body
    static let body: Font = .body
    static let bodyMedium: Font = .body.weight(.medium)
    static let bodySemibold: Font = .body.weight(.semibold)

    // Callout
    static let callout: Font = .callout
    static let calloutMedium: Font = .callout.weight(.medium)
    static let calloutSemibold: Font = .callout.weight(.semibold)

    // Footnote
    static let footnote: Font = .footnote
    static let footnoteMedium: Font = .footnote.weight(.medium)

    // Caption
    static let caption: Font = .caption.weight(.medium)
    static let captionRegular: Font = .caption
    static let captionSemibold: Font = .caption.weight(.semibold)
    static let captionSmall: Font = .caption2.weight(.semibold)
    static let captionSmallMedium: Font = .caption2.weight(.medium)
    static let captionSmallRegular: Font = .caption2

    // Micro — AI classification tags, tiny badges
    static let microTag: Font = .system(size: 9, weight: .medium)
}

// MARK: - Elevation

struct ElevationModifier: ViewModifier {
    let level: ElevationLevel

    enum ElevationLevel {
        case navigation
        case transient
        case elevated
    }

    func body(content: Content) -> some View {
        switch level {
        case .navigation:
            content.shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        case .transient:
            content.shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
        case .elevated:
            content.shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 8)
        }
    }
}

extension View {
    func elevation(_ level: ElevationModifier.ElevationLevel) -> some View {
        modifier(ElevationModifier(level: level))
    }
}

// MARK: - Selectable Row Style

struct SelectableRowStyle: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(
                isSelected ? AnyShapeStyle(.tint)
                : isHovered ? AnyShapeStyle(.primary)
                : AnyShapeStyle(.secondary)
            )
    }
}

extension View {
    func selectableRowStyle(isSelected: Bool, isHovered: Bool) -> some View {
        modifier(SelectableRowStyle(isSelected: isSelected, isHovered: isHovered))
    }
}

// MARK: - Destructive Action Style

struct DestructiveActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Typography.subhead)
            .foregroundStyle(.red)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.red.opacity(0.1), in: .rect(cornerRadius: CornerRadius.sm))
    }
}

extension View {
    func destructiveActionStyle() -> some View {
        modifier(DestructiveActionStyle())
    }
}

// MARK: - Toolbar Icon Button

struct ToolbarIconButton: View {
    let icon: String
    let label: String
    var size: CGFloat = ButtonSize.md
    var font: Font = Typography.body
    var useGlass: Bool = false
    let action: () -> Void

    var body: some View {
        Group {
            if useGlass {
                Button(action: action) {
                    Image(systemName: icon)
                        .font(font)
                        .frame(width: size, height: size)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.glass)
            } else {
                Button(action: action) {
                    Image(systemName: icon)
                        .font(font)
                        .frame(width: size, height: size)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .help(label)
    }
}

// MARK: - Floating Panel Style

struct FloatingPanelStyle: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .elevation(.transient)
    }
}

extension View {
    func floatingPanelStyle(cornerRadius: CGFloat = CornerRadius.md) -> some View {
        modifier(FloatingPanelStyle(cornerRadius: cornerRadius))
    }
}

// MARK: - Glass or Material Modifier

struct GlassOrMaterial<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    init(in shape: S, interactive: Bool = false) {
        self.shape = shape
        self.interactive = interactive
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background(shape.fill(.regularMaterial))
                .clipShape(shape)
        }
    }
}

extension View {
    func glassOrMaterial<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(GlassOrMaterial(in: shape, interactive: interactive))
    }
}

