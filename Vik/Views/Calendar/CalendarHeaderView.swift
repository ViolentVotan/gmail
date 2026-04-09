import SwiftUI

// MARK: - CalendarHeaderView

struct CalendarHeaderView: View {
    @Bindable var viewModel: CalendarViewModel
    var onNewEvent: () -> Void
    @Namespace private var viewModeNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cachedDateRangeText: String = ""
    @State private var viewModeHovers: [CalendarViewMode: Bool] = [:]

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
        .clipped()
        .task {
            recomputeDateRangeText()
        }
        .onChange(of: viewModel.selectedDate) {
            recomputeDateRangeText()
        }
        .onChange(of: viewModel.viewMode) {
            recomputeDateRangeText()
        }
    }

    // MARK: - Subviews

    private var navigationButtons: some View {
        let modeLabel = viewModel.viewMode.label.lowercased()
        return HStack(spacing: Spacing.xs) {
            Button {
                withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                    viewModel.navigateBackward()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(Typography.body)
                    .frame(width: ButtonSize.md, height: ButtonSize.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .help("Previous \(modeLabel)")
            .accessibilityLabel("Previous \(modeLabel)")

            Button {
                withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                    viewModel.navigateForward()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(Typography.body)
                    .frame(width: ButtonSize.md, height: ButtonSize.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .help("Next \(modeLabel)")
            .accessibilityLabel("Next \(modeLabel)")
        }
    }

    private var dateRangeLabel: some View {
        Text(cachedDateRangeText)
            .font(Typography.subheadSemibold)
            .foregroundStyle(.primary)
            .monospacedDigit()
    }

    private var todayButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                viewModel.goToToday()
            }
        } label: {
            Text("Today")
                .font(Typography.captionSemibold)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
        }
        .buttonStyle(.glass)
        .help("Go to today")
        .accessibilityLabel("Go to today")
    }

    private var viewModePicker: some View {
        GlassEffectContainer(spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xxs) {
                ForEach([CalendarViewMode.month, .week, .day, .agenda], id: \.self) { mode in
                    let isSelected = viewModel.viewMode == mode
                    Button {
                        withAnimation(reduceMotion ? nil : VikAnimation.contentSwitch) {
                            viewModel.viewMode = mode
                        }
                    } label: {
                        Text(mode.label)
                            .font(Typography.captionSemibold)
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xs)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .onHover { viewModeHovers[mode] = $0 }
                    .glassEffect(
                        isSelected || (viewModeHovers[mode] ?? false) ? .regular.interactive() : .identity,
                        in: .capsule
                    )
                    .glassEffectID(isSelected ? "selectedViewMode" : mode.rawValue, in: viewModeNamespace)
                    .sensoryFeedback(.selection, trigger: isSelected)
                    .help("\(mode.label) view")
                    .accessibilityLabel("\(mode.label) view")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .accessibilityLabel("Calendar view mode")
    }

    private var newEventButton: some View {
        Button(action: onNewEvent) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "plus")
                    .font(Typography.captionSemibold)
                Text("New Event")
                    .font(Typography.captionSemibold)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, Spacing.md)
            .frame(height: ButtonSize.md)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("New Event")
        .help("Create new event")
    }

    // MARK: - Helpers

    private func recomputeDateRangeText() {
        switch viewModel.viewMode {
        case .month:
            cachedDateRangeText = viewModel.selectedDate.formatted(.dateTime.month(.wide).year())
        case .day:
            cachedDateRangeText = viewModel.selectedDate.formatted(date: .abbreviated, time: .omitted)
        case .week, .agenda:
            cachedDateRangeText = weekRangeText
        }
    }

    private static let weekRangeEndSameMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d, yyyy"
        return f
    }()

    private var weekRangeText: String {
        let week = viewModel.selectedWeek
        let start = week.start
        let end = Calendar.current.date(byAdding: .day, value: -1, to: week.end) ?? week.end

        let startMonth = Calendar.current.component(.month, from: start)
        let endMonth = Calendar.current.component(.month, from: end)
        let startYear = Calendar.current.component(.year, from: start)
        let endYear = Calendar.current.component(.year, from: end)

        let startText: String
        let endText: String

        if startYear != endYear {
            startText = start.formattedShortDateYear
            endText = end.formattedShortDateYear
        } else if startMonth != endMonth {
            startText = start.formattedShortDate
            endText = end.formattedShortDateYear
        } else {
            startText = start.formattedShortDate
            endText = Self.weekRangeEndSameMonthFormatter.string(from: end)
        }

        return "\(startText) – \(endText)"
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarHeaderView(viewModel: vm, onNewEvent: {})
        .frame(width: 900)
}
