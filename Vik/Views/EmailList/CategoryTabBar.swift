import SwiftUI

struct CategoryTabBar: View {
    @Binding var selectedCategory: InboxCategory
    let unreadCounts: [InboxCategory: Int]
    @State private var hoveredCategory: InboxCategory?
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
                        categoryTab(category)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    private func categoryTab(_ category: InboxCategory) -> some View {
        let isSelected = selectedCategory == category
        let isHovered = hoveredCategory == category

        return Button {
            withAnimation(.smooth) {
                selectedCategory = category
            }
        } label: {
            HStack(spacing: 4) {
                Text(category.displayName)
                    .font(Typography.subheadRegular)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .fixedSize()

                if let count = unreadCounts[category], count > 0 {
                    Text("\(count)")
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
            hoveredCategory = hovering ? category : nil
        }
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        .accessibilityLabel(category.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(category.displayName)
    }
}

#Preview {
    @Previewable @State var selectedCategory: InboxCategory = .all

    CategoryTabBar(
        selectedCategory: $selectedCategory,
        unreadCounts: [.primary: 3, .social: 12, .promotions: 47]
    )
    .frame(width: 380)
}
