import SwiftUI

/// Reusable unread-count badge used across the sidebar.
///
/// Displays the count capped at "99+" inside a capsule whose colours
/// adapt to the current theme and selection state.
struct BadgeView: View {
    let count: Int
    let isSelected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        Text(count < 100 ? "\(count)" : "99+")
            .font(.serifBadge)
            .foregroundColor(isSelected ? theme.sidebarBadgeText : theme.sidebarTextMuted)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.sidebarBadge))
    }
}
