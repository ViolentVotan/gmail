import SwiftUI

// MARK: - CalendarHeaderView

struct CalendarHeaderView: View {
    @Bindable var viewModel: CalendarViewModel
    var onNewEvent: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            navigationButtons
            Spacer()
            dateRangeLabel
            Spacer()
            todayButton
            viewModePicker
            newEventButton
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(.bar)
    }

    // MARK: - Subviews

    private var navigationButtons: some View {
        HStack(spacing: Spacing.xs) {
            Button {
                withAnimation(VikAnimation.springSnappy) {
                    viewModel.navigateBackward()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(Typography.body)
                    .frame(width: ButtonSize.md, height: ButtonSize.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Previous week")

            Button {
                withAnimation(VikAnimation.springSnappy) {
                    viewModel.navigateForward()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(Typography.body)
                    .frame(width: ButtonSize.md, height: ButtonSize.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Next week")
        }
    }

    private var dateRangeLabel: some View {
        Text(weekRangeText)
            .font(Typography.subheadSemibold)
            .foregroundStyle(.primary)
            .monospacedDigit()
    }

    private var todayButton: some View {
        Button {
            withAnimation(VikAnimation.springSnappy) {
                viewModel.goToToday()
            }
        } label: {
            Text("Today")
                .font(Typography.captionSemibold)
                .foregroundStyle(BrandColor.blue)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(
                    BrandColor.blue.opacity(0.12),
                    in: .capsule
                )
        }
        .buttonStyle(.plain)
        .help("Go to today")
    }

    private var viewModePicker: some View {
        Picker("View", selection: $viewModel.viewMode) {
            Text("Day").tag(CalendarViewMode.day)
            Text("Week").tag(CalendarViewMode.week)
            Text("Agenda").tag(CalendarViewMode.agenda)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
    }

    private var newEventButton: some View {
        Button(action: onNewEvent) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "plus")
                    .font(Typography.captionSemibold)
                Text("New Event")
                    .font(Typography.captionSemibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.md)
            .frame(height: ButtonSize.md)
            .background(BrandColor.blue, in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Create new event")
    }

    // MARK: - Helpers

    private var weekRangeText: String {
        let week = viewModel.selectedWeek
        let start = week.start
        let end = Calendar.current.date(byAdding: .day, value: -1, to: week.end) ?? week.end

        let startFormatter = DateFormatter()
        let endFormatter = DateFormatter()

        let startMonth = Calendar.current.component(.month, from: start)
        let endMonth = Calendar.current.component(.month, from: end)
        let startYear = Calendar.current.component(.year, from: start)
        let endYear = Calendar.current.component(.year, from: end)

        if startYear != endYear {
            startFormatter.dateFormat = "MMM d, yyyy"
            endFormatter.dateFormat = "MMM d, yyyy"
        } else if startMonth != endMonth {
            startFormatter.dateFormat = "MMM d"
            endFormatter.dateFormat = "MMM d, yyyy"
        } else {
            startFormatter.dateFormat = "MMM d"
            endFormatter.dateFormat = "d, yyyy"
        }

        return "\(startFormatter.string(from: start)) – \(endFormatter.string(from: end))"
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarHeaderView(viewModel: vm, onNewEvent: {})
        .frame(width: 900)
}
