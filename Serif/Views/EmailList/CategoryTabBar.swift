import SwiftUI

struct CategoryTabBar: View {
    @Binding var selectedCategory: InboxCategory
    @Binding var priorityFilterOn: Bool
    let unreadCounts: [InboxCategory: Int]

    var body: some View {
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
                    .font(.caption)
                    .foregroundStyle(priorityFilterOn ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Show only important emails")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func categoryTab(_ category: InboxCategory) -> some View {
        Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 4) {
                Text(category.displayName)
                    .font(.subheadline)
                    .fontWeight(selectedCategory == category ? .semibold : .regular)

                if let count = unreadCounts[category], count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(selectedCategory == category ? Color.accentColor : .secondary.opacity(0.2))
                        .foregroundStyle(selectedCategory == category ? .white : .secondary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selectedCategory == category ? Color.accentColor.opacity(0.1) : .clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedCategory == category ? Color.accentColor : .secondary)
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
