import SwiftUI

struct CategoryTabBar: View {
    @Binding var selectedCategory: InboxCategory
    let unreadCounts: [InboxCategory: Int]

    var body: some View {
        tabBarContent
    }

    private var tabBarContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(InboxCategory.allCases) { category in
                    categoryTab(category)
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    private func categoryTab(_ category: InboxCategory) -> some View {
        let isSelected = selectedCategory == category

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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .modifier(TabBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        .accessibilityLabel(category.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TabBackground: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        if isSelected {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear), in: .capsule)
                .onHover { isHovered = $0 }
        }
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
