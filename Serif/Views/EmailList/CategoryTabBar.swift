import SwiftUI

struct CategoryTabBar: View {
    @Binding var selectedCategory: InboxCategory
    @Binding var priorityFilterOn: Bool
    let unreadCounts: [InboxCategory: Int]

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer {
                    tabBarContent
                }
            } else {
                tabBarContent
            }
        }
    }

    private var tabBarContent: some View {
        HStack(spacing: 0) {
            ForEach(InboxCategory.allCases) { category in
                categoryTab(category)
            }

            Spacer()

            // Priority filter toggle (Gmail IMPORTANT label)
            Button {
                priorityFilterOn.toggle()
            } label: {
                Label("Priority", systemImage: priorityFilterOn ? "flag.fill" : "flag")
                    .font(Typography.captionRegular)
                    .foregroundStyle(priorityFilterOn ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Show only important emails")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
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

                if let count = unreadCounts[category], count > 0 {
                    Text("\(count)")
                        .font(Typography.captionSmallMedium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.accentColor : .secondary.opacity(0.2))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
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

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if isSelected {
                content.glassEffect(.regular, in: .capsule)
            } else {
                content
            }
        } else {
            content.background(isSelected ? Color.accentColor.opacity(0.1) : .clear, in: .capsule)
        }
    }
}

#Preview {
    @Previewable @State var selectedCategory: InboxCategory = .all
    @Previewable @State var priorityFilterOn: Bool = false

    CategoryTabBar(
        selectedCategory: $selectedCategory,
        priorityFilterOn: $priorityFilterOn,
        unreadCounts: [.primary: 3, .social: 12, .promotions: 47]
    )
    .frame(width: 700)
}
