import SwiftUI

// MARK: - CalendarListSidebarView

struct CalendarListSidebarView: View {
    @Bindable var viewModel: CalendarViewModel
    var onNewEvent: () -> Void

    @State private var calendarsByAccount: [(accountID: String, calendars: [CalendarInfo])] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            calendarSections
            newEventButton
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.md)
        }
        .task { recomputeCalendars() }
        .onChange(of: viewModel.calendars) { _, _ in recomputeCalendars() }
    }

    private func recomputeCalendars() {
        let grouped = Dictionary(grouping: viewModel.calendars, by: \.accountID)
        calendarsByAccount = grouped
            .map { (accountID: $0.key, calendars: $0.value.sorted { $0.isPrimary && !$1.isPrimary }) }
            .sorted { $0.accountID < $1.accountID }
    }

    // MARK: - Calendar Sections

    @ViewBuilder
    private var calendarSections: some View {
        ForEach(calendarsByAccount, id: \.accountID) { group in
            VStack(alignment: .leading, spacing: 2) {
                Text(group.accountID)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xs)

                ForEach(group.calendars) { calendar in
                    calendarRow(calendar)
                }
            }
        }
    }

    private func calendarRow(_ calendar: CalendarInfo) -> some View {
        Button {
            Task { await viewModel.toggleCalendarVisibility(calendar) }
        } label: {
            HStack(spacing: Spacing.sm) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: calendar.backgroundColor))
                    .frame(width: 10, height: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color(hex: calendar.backgroundColor).opacity(0.3), lineWidth: 0.5)
                    )

                Text(calendar.summaryOverride ?? calendar.summary)
                    .font(Typography.captionRegular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Image(systemName: calendar.isVisible ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(
                        calendar.isVisible
                            ? Color(hex: calendar.backgroundColor)
                            : Color.secondary
                    )
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await viewModel.toggleCalendarVisibility(calendar) }
            } label: {
                Label(
                    calendar.isVisible ? "Hide Calendar" : "Show Calendar",
                    systemImage: calendar.isVisible ? "eye.slash" : "eye"
                )
            }

            if let link = URL(string: "https://calendar.google.com/calendar/r?cid=\(calendar.calendarId)") {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Label("Open in Google Calendar", systemImage: "safari")
                }
            }
        }
    }

    // MARK: - New Event Button

    private var newEventButton: some View {
        Button(action: onNewEvent) {
            Label("New Event", systemImage: "plus")
                .font(Typography.captionSemibold)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: CornerRadius.md))
    }
}

#Preview {
    @Previewable @State var vm = CalendarViewModel(db: try! MailDatabase(accountID: "preview"))
    CalendarListSidebarView(viewModel: vm, onNewEvent: { })
        .frame(width: 220)
        .padding()
}
