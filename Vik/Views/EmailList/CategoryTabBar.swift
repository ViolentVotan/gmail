import SwiftUI

struct CategoryTabBar: View {
    @Binding var selectedCategory: InboxCategory
    let unreadCounts: [InboxCategory: Int]
    @State private var hoveredCategory: InboxCategory?

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
            selectedCategory = category
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
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.fill.quaternary))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected || isHovered ? .regular.interactive() : .identity,
            in: .capsule
        )
        .animation(.snappy(duration: 0.2), value: isSelected)
        .animation(.snappy(duration: 0.2), value: isHovered)
        .onHover { hovering in
            hoveredCategory = hovering ? category : nil
        }
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        .accessibilityLabel(category.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
