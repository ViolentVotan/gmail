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

// MARK: - Corner Radius

enum CornerRadius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
}

// MARK: - Animation

enum SerifAnimation {
    static let springDefault = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let springSnappy = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let springGentle = Animation.spring(response: 0.4, dampingFraction: 0.9)
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

// MARK: - Floating Panel Style

struct FloatingPanelStyle: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
    }
}

extension View {
    func floatingPanelStyle(cornerRadius: CGFloat = CornerRadius.md) -> some View {
        modifier(FloatingPanelStyle(cornerRadius: cornerRadius))
    }
}
