// Vik/Views/Calendar/CalendarMonthEventChip.swift
import SwiftUI

// MARK: - CalendarMonthEventChip

/// Compact event chip for month view day cells.
struct CalendarMonthEventChip: View {
    let event: CalendarEvent
    var onSelect: (CalendarEvent) -> Void = { _ in }

    /// Pre-formatted time string (e.g. "14:30") computed once at init, not per body evaluation.
    private let formattedStartTime: String

    @State private var isHovered = false
    @GestureState private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 24-hour "HH:mm" formatter matching the previous `.dateTime.hour(.twoDigits(amPM: .omitted)).minute()`.
    private static let chipTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(event: CalendarEvent, onSelect: @escaping (CalendarEvent) -> Void = { _ in }) {
        self.event = event
        self.onSelect = onSelect
        self.formattedStartTime = Self.chipTimeFormatter.string(from: event.startTime)
    }

    var body: some View {
        HStack(spacing: 3) {
            if !event.isAllDay {
                // Timed event: colored dot + time + title
                Circle()
                    .fill(event.resolvedColor)
                    .frame(width: 6, height: 6)
                Text(formattedStartTime)
                    .font(Typography.calendarEventTime)
                    .foregroundStyle(.secondary)
                Text(event.summary)
                    .font(Typography.calendarEventTime)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                // All-day event: filled chip
                Text(event.summary)
                    .font(Typography.calendarEventTime)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, Spacing.xs)
            }
        }
        .frame(height: CalendarLayout.monthEventChipHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, event.isAllDay ? 0 : Spacing.xs)
        .background {
            if event.isAllDay {
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .fill(event.resolvedColor.opacity(CalendarSemanticColor.eventCardBackgroundOpacity))
            }
        }
        .glassEffect(
            isHovered ? .regular.interactive() : .identity,
            in: .rect(cornerRadius: CornerRadius.sm)
        )
        .shadow(
            color: isHovered ? event.resolvedColor.opacity(0.2) : .clear,
            radius: isHovered ? 4 : 0,
            y: isHovered ? 2 : 0
        )
        .scaleEffect(reduceMotion ? 1.0 : (isPressed ? ScaleToken.press : (isHovered ? ScaleToken.hover : 1.0)))
        .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: isPressed)
        .animation(reduceMotion ? nil : VikAnimation.springDefault, value: isHovered)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
                .onEnded { _ in onSelect(event) }
        )
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .accessibilityLabel(event.isAllDay
            ? event.summary
            : "\(event.startTime.formatted(date: .omitted, time: .shortened)) \(event.summary)")
        .accessibilityAddTraits(.isButton)
        .help(event.summary)
    }
}

// MARK: - CalendarMonthSpanningBar

/// Spanning bar for multi-day events rendered in the week row's spanning area.
struct CalendarMonthSpanningBar: View {
    let event: CalendarEvent
    let startColumn: Int
    let endColumn: Int
    let columnWidth: CGFloat
    /// True if the event actually starts before this week (bar is clipped at leading edge).
    let isClippedAtStart: Bool
    /// True if the event actually ends after this week (bar is clipped at trailing edge).
    let isClippedAtEnd: Bool
    var onSelect: (CalendarEvent) -> Void = { _ in }

    @State private var isHovered = false
    @GestureState private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var leadingRadius: CGFloat { isClippedAtStart ? 0 : CornerRadius.sm }
    private var trailingRadius: CGFloat { isClippedAtEnd ? 0 : CornerRadius.sm }

    var body: some View {
        Text(event.summary)
            .font(Typography.calendarEventTime)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.xs)
            .frame(height: CalendarLayout.monthSpanningBarHeight)
            .frame(width: CGFloat(endColumn - startColumn + 1) * columnWidth - 2, alignment: .leading)
            .background(
                event.resolvedColor.opacity(CalendarSemanticColor.eventCardBackgroundOpacity),
                in: .rect(
                    topLeadingRadius: leadingRadius,
                    bottomLeadingRadius: leadingRadius,
                    bottomTrailingRadius: trailingRadius,
                    topTrailingRadius: trailingRadius
                )
            )
            .glassEffect(
                isHovered ? .regular.interactive() : .identity,
                in: .rect(
                    topLeadingRadius: leadingRadius,
                    bottomLeadingRadius: leadingRadius,
                    bottomTrailingRadius: trailingRadius,
                    topTrailingRadius: trailingRadius
                )
            )
            .shadow(
                color: isHovered ? event.resolvedColor.opacity(0.2) : .clear,
                radius: isHovered ? 4 : 0,
                y: isHovered ? 2 : 0
            )
            .scaleEffect(reduceMotion ? 1.0 : (isPressed ? ScaleToken.press : (isHovered ? ScaleToken.hover : 1.0)))
            .animation(reduceMotion ? nil : VikAnimation.springSnappy, value: isPressed)
            .animation(reduceMotion ? nil : VikAnimation.springDefault, value: isHovered)
            .offset(x: CGFloat(startColumn) * columnWidth + 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in state = true }
                    .onEnded { _ in onSelect(event) }
            )
            .onHover { isHovered = $0 }
            .accessibilityLabel(event.summary)
            .accessibilityAddTraits(.isButton)
            .help(event.summary)
    }
}
