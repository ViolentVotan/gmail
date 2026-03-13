import SwiftUI

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

            ForEach(presets, id: \.label) { preset in
                Button {
                    onSelect(preset.date)
                } label: {
                    HStack {
                        Label(preset.label, systemImage: preset.icon)
                        Spacer()
                        Text(preset.subtitle)
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

    private var presets: [(label: String, icon: String, subtitle: String, date: Date)] {
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

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE, h:mm a"

        return [
            ("Later Today", "clock", formatter.string(from: laterToday), laterToday),
            ("Tomorrow Morning", "sunrise", "8:00 AM", tomorrowMorning),
            ("Next Week", "calendar", dayFormatter.string(from: nextMonday), nextMonday),
        ]
    }
}
