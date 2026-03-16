import AppKit
import SwiftUI

// MARK: - Spacing

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
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

// MARK: - Brand Colors

enum BrandColor {
    /// Serif coral — warm accent for brand moments and onboarding.
    static let coral  = Color(red: 0.94, green: 0.44, blue: 0.44)   // #F07070
    /// Serif blue — canonical brand color, matching AccentColor (light).
    static let blue   = Color(red: 0.227, green: 0.435, blue: 0.941) // #3A6FF0
    /// Serif violet — onboarding bridge accent between blue and coral.
    static let violet = Color(red: 0.639, green: 0.443, blue: 0.969) // #A371F7
}

// MARK: - Adaptive Color

extension Color {
    /// Creates a color that automatically resolves for the current appearance (light/dark).
    /// Uses `NSColor(name:dynamicProvider:)` for zero-cost appearance tracking.
    static func adaptive(
        light: (red: CGFloat, green: CGFloat, blue: CGFloat),
        dark: (red: CGFloat, green: CGFloat, blue: CGFloat)
    ) -> Color {
        let lightColor = NSColor(srgbRed: light.red, green: light.green, blue: light.blue, alpha: 1)
        let darkColor = NSColor(srgbRed: dark.red, green: dark.green, blue: dark.blue, alpha: 1)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }))
    }
}

// MARK: - Semantic State Colors

/// Curated state colors — desaturated and brand-tinted for a cohesive premium feel.
/// Each color adapts to light/dark appearance automatically.
enum SemanticColor {
    /// Teal-green — sync complete, auth pass, positive sentiment.
    static let success = Color.adaptive(
        light: (red: 0.18, green: 0.65, blue: 0.47),
        dark:  (red: 0.30, green: 0.78, blue: 0.58)
    )
    /// Warm rose — sync fail, destructive actions, negative sentiment.
    static let error = Color.adaptive(
        light: (red: 0.82, green: 0.28, blue: 0.32),
        dark:  (red: 0.92, green: 0.45, blue: 0.45)
    )
    /// Amber — nudge, offline, action needed, urgent.
    static let warning = Color.adaptive(
        light: (red: 0.83, green: 0.56, blue: 0.20),
        dark:  (red: 0.95, green: 0.70, blue: 0.32)
    )
}

// MARK: - File Type Colors

/// Muted, cohesive palette for attachment file-type indicators.
/// Each color adapts to light/dark appearance automatically.
enum FileTypeColor {
    static let image        = Color.adaptive(light: (0.30, 0.50, 0.92), dark: (0.42, 0.60, 0.95))
    static let pdf          = Color.adaptive(light: (0.82, 0.32, 0.35), dark: (0.90, 0.45, 0.45))
    static let spreadsheet  = Color.adaptive(light: (0.20, 0.65, 0.50), dark: (0.30, 0.75, 0.58))
    static let document     = Color.adaptive(light: (0.38, 0.40, 0.88), dark: (0.48, 0.50, 0.92))
    static let presentation = Color.adaptive(light: (0.85, 0.55, 0.22), dark: (0.92, 0.65, 0.32))
    static let archive      = Color.adaptive(light: (0.55, 0.45, 0.78), dark: (0.65, 0.55, 0.85))
    static let code         = Color.adaptive(light: (0.25, 0.60, 0.72), dark: (0.35, 0.70, 0.82))
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

    // Headline
    static let headline: Font = .headline

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
        case transient
        case elevated
    }

    func body(content: Content) -> some View {
        switch level {
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

// MARK: - Destructive Action Style

struct DestructiveActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Typography.subhead)
            .foregroundStyle(SemanticColor.error)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(SemanticColor.error.opacity(0.1), in: .rect(cornerRadius: CornerRadius.sm))
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

// MARK: - Dropdown Panel Style

struct DropdownPanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.md))
            .overlay(RoundedRectangle(cornerRadius: CornerRadius.md).strokeBorder(.separator, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
    }
}

extension View {
    func dropdownPanelStyle() -> some View {
        modifier(DropdownPanelStyle())
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
        if interactive {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    func glassOrMaterial<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(GlassOrMaterial(in: shape, interactive: interactive))
    }
}

// MARK: - Haptic Feedback

@MainActor
enum SerifHaptic {
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }

    static func alignment() { perform(.alignment) }
    static func generic() { perform(.generic) }
    static func levelChange() { perform(.levelChange) }
}

