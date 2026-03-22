import SwiftUI

struct CategoryTabBar: View {
    @Binding var selectedCategory: InboxCategory
    let unreadCounts: [InboxCategory: Int]
    @Namespace private var tabNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        tabBarContent
    }

    private var tabBarContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(InboxCategory.allCases) { category in
                        CategoryTabButton(
                            category: category,
                            isSelected: selectedCategory == category,
                            unreadCount: unreadCounts[category] ?? 0,
                            reduceMotion: reduceMotion,
                            tabNamespace: tabNamespace
                        ) {
                            withAnimation(.smooth) {
                                selectedCategory = category
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }
}

private struct CategoryTabButton: View {
    let category: InboxCategory
    let isSelected: Bool
    let unreadCount: Int
    let reduceMotion: Bool
    var tabNamespace: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(category.displayName)
                    .font(Typography.subheadRegular)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .fixedSize()

                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(Typography.captionSmall)
                        .foregroundStyle(isSelected ? .primary : .tertiary)
                        .contentTransition(.numericText())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.fill.quaternary))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.interactive(),
            in: .capsule
        )
        .glassEffectID(isSelected ? "selectedTab" : category.rawValue, in: tabNamespace)
        .scaleEffect(reduceMotion ? 1.0 : (isHovered && !isSelected ? ScaleToken.rowHover : 1.0))
        .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isSelected)
        .sensoryFeedback(.selection, trigger: isSelected)
        .animation(reduceMotion ? nil : VikAnimation.hoverFeedback, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        .accessibilityLabel(category.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(category.displayName)
    }
}
