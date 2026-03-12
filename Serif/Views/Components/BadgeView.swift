import SwiftUI

/// Reusable unread-count badge used across the sidebar.
///
/// Displays the count capped at "99+" inside a capsule whose colours
/// adapt to the current theme and selection state.
struct BadgeView: View {
    let count: Int
    let isSelected: Bool
    var body: some View {
        Text(count < 100 ? "\(count)" : "99+")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(isSelected ? 0.2 : 0.12)))
    }
}
