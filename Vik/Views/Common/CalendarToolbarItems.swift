import SwiftUI

struct CalendarToolbarItems: ToolbarContent {
    let onNewEvent: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: onNewEvent) {
                Label("New Event", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help("New Event (\u{2318}N)")
        }
    }
}
