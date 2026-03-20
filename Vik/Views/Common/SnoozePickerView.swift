import SwiftUI

// MARK: - Snooze Preset

struct SnoozePreset: Identifiable {
    let id: String
    let title: String
    let icon: String
    let date: Date

    /// Tomorrow at 8:00 AM — default snooze target for hover quick-action.
    static var tomorrowMorning: Date {
        let calendar = Calendar.current
        let now = Date()
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return now }
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    static func defaults() -> [SnoozePreset] {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)

        let laterToday: Date = {
            if hour < 15 {
                return calendar.date(byAdding: .hour, value: 3, to: now) ?? now
            } else {
                return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
            }
        }()

        let nextMonday: Date = {
            let weekday = calendar.component(.weekday, from: now)
            let daysUntilMonday = (9 - weekday) % 7
            let adjustedDays = daysUntilMonday == 0 ? 7 : daysUntilMonday
            guard let monday = calendar.date(byAdding: .day, value: adjustedDays, to: now) else { return now }
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: monday) ?? monday
        }()

        return [
            SnoozePreset(id: "later", title: "Later Today", icon: "clock", date: laterToday),
            SnoozePreset(id: "tomorrow", title: "Tomorrow Morning", icon: "sunrise", date: tomorrowMorning),
            SnoozePreset(id: "nextweek", title: "Next Week", icon: "calendar", date: nextMonday),
        ]
    }
}

// MARK: - Snooze Picker View

struct SnoozePickerView: View {
    var title: String = "Snooze until..."
    let onSelect: (Date) -> Void
    @State private var showCustomPicker = false
    @State private var customDate = Date()
    @State private var presets = SnoozePreset.defaults()
    @State private var hoveredPresetID: String?
    @State private var isPickDateHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Typography.subheadSemibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            ForEach(presets) { preset in
                Button {
                    onSelect(preset.date)
                } label: {
                    HStack {
                        Label(preset.title, systemImage: preset.icon)
                        Spacer()
                        Text(preset.date.formattedTime)
                            .font(Typography.captionRegular)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .glassEffect(hoveredPresetID == preset.id ? .regular.interactive() : .identity, in: .rect(cornerRadius: CornerRadius.sm))
                .onHover { hoveredPresetID = $0 ? preset.id : nil }
            }

            Divider()

            if showCustomPicker {
                DatePicker("Pick a date", selection: $customDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .padding(.horizontal, 8)

                Button("Confirm") {
                    onSelect(customDate)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            } else {
                Button {
                    showCustomPicker = true
                } label: {
                    Label("Pick Date & Time", systemImage: "calendar")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .glassEffect(isPickDateHovered ? .regular.interactive() : .identity, in: .rect(cornerRadius: CornerRadius.sm))
                .onHover { isPickDateHovered = $0 }
            }
        }
        .frame(width: 260)
        .padding(.vertical, 4)
    }

}
