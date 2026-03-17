import SwiftUI

// MARK: - Snooze Preset

struct SnoozePreset: Identifiable {
    let id: String
    let title: String
    let icon: String
    let date: Date

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

        let tomorrowMorning: Date = {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return now }
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Typography.subheadSemibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            ForEach(SnoozePreset.defaults()) { preset in
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
                }
                .buttonStyle(.plain)
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
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 260)
        .padding(.vertical, 4)
    }

}
