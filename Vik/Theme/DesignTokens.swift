import AppKit
import SwiftUI

// MARK: - Spacing

enum Spacing {
    static let xxxs: CGFloat = 1
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let xsm: CGFloat = 6
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum ButtonSize {
    static let sm: CGFloat = 26
    static let md: CGFloat = 28
    static let lg: CGFloat = 30
}

// MARK: - Corner Radius

enum CornerRadius {
    static let indicator: CGFloat = 1
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Google Brand Colors

enum GoogleBrandColor {
    static let blue   = Color(red: 0.263, green: 0.522, blue: 0.957)  // #4285F4
    static let red    = Color(red: 0.918, green: 0.263, blue: 0.208)  // #EA4335
    static let yellow = Color(red: 0.984, green: 0.737, blue: 0.020)  // #FBBC05
    static let green  = Color(red: 0.204, green: 0.659, blue: 0.325)  // #34A853
}

// MARK: - Brand Colors

enum BrandColor {
    /// Vik coral — warm accent for brand moments, onboarding, and current-time indicator.
    static let coral = Color.adaptive(
        light: (red: 0.94, green: 0.44, blue: 0.44),  // #F07070
        dark:  (red: 1.00, green: 0.55, blue: 0.55)   // Brighter for dark backgrounds
    )
    /// Vik blue — canonical brand color, matching AccentColor (light).
    static let blue   = Color(red: 0.227, green: 0.435, blue: 0.941) // #3A6FF0
    /// Adaptive blue for text — meets 4.5:1 contrast in both light and dark.
    static let blueText = Color.adaptive(
        light: (red: 0.18, green: 0.38, blue: 0.88),
        dark:  (red: 0.42, green: 0.58, blue: 0.98)
    )
    /// Vik violet — onboarding bridge accent between blue and coral.
    static let violet = Color(red: 0.639, green: 0.443, blue: 0.969) // #A371F7
    /// Near-black background for the onboarding window.
    static let onboardingBackground = Color(red: 0.031, green: 0.035, blue: 0.047) // #080910
}

// MARK: - Adaptive Color

extension Color {
    /// Creates a color that automatically resolves for the current appearance (light/dark).
    /// Uses `NSColor(name:dynamicProvider:)` for zero-cost appearance tracking.
    static func adaptive(
        light: (red: CGFloat, green: CGFloat, blue: CGFloat),
        dark: (red: CGFloat, green: CGFloat, blue: CGFloat)
    ) -> Color {
        let lightColor = NSColor(srgbRed: light.red, green: light.green, blue: light.blue, alpha: 1)
        let darkColor = NSColor(srgbRed: dark.red, green: dark.green, blue: dark.blue, alpha: 1)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }))
    }
}

// MARK: - Semantic State Colors

/// Curated state colors — desaturated and brand-tinted for a cohesive premium feel.
/// Each color adapts to light/dark appearance automatically.
enum SemanticColor {
    /// Teal-green — sync complete, auth pass, positive sentiment.
    static let success = Color.adaptive(
        light: (red: 0.18, green: 0.65, blue: 0.47),
        dark:  (red: 0.30, green: 0.78, blue: 0.58)
    )
    /// Warm rose — sync fail, destructive actions, negative sentiment.
    static let error = Color.adaptive(
        light: (red: 0.82, green: 0.28, blue: 0.32),
        dark:  (red: 0.92, green: 0.45, blue: 0.45)
    )
    /// Amber — nudge, offline, action needed, urgent.
    /// Light variant darkened to meet WCAG 4.5:1 on white backgrounds.
    static let warning = Color.adaptive(
        light: (red: 0.68, green: 0.44, blue: 0.06),
        dark:  (red: 0.95, green: 0.70, blue: 0.32)
    )
}

// MARK: - File Type Colors

/// Muted, cohesive palette for attachment file-type indicators.
/// Each color adapts to light/dark appearance automatically.
enum FileTypeColor {
    static let image        = Color.adaptive(light: (0.30, 0.50, 0.92), dark: (0.42, 0.60, 0.95))
    static let pdf          = Color.adaptive(light: (0.82, 0.32, 0.35), dark: (0.90, 0.45, 0.45))
    static let spreadsheet  = Color.adaptive(light: (0.20, 0.65, 0.50), dark: (0.30, 0.75, 0.58))
    static let document     = Color.adaptive(light: (0.38, 0.40, 0.88), dark: (0.48, 0.50, 0.92))
    static let presentation = Color.adaptive(light: (0.85, 0.55, 0.22), dark: (0.92, 0.65, 0.32))
    static let archive      = Color.adaptive(light: (0.55, 0.45, 0.78), dark: (0.65, 0.55, 0.85))
    static let code         = Color.adaptive(light: (0.25, 0.60, 0.72), dark: (0.35, 0.70, 0.82))
}

// MARK: - Animation

enum VikAnimation {
    static let springDefault = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let springSnappy = Animation.spring(response: 0.28, dampingFraction: 0.78)
    static let springGentle = Animation.spring(response: 0.4, dampingFraction: 0.88)
    /// Content swap — crossfade with subtle spring for email/category transitions.
    static let contentSwitch = Animation.smooth(duration: 0.25)
    /// Folder/account switch — slightly longer crossfade for larger content areas.
    static let folderSwitch = Animation.smooth(duration: 0.3)
    /// Micro-interaction — quick spring bounce for toggles (star, read).
    static let microBounce = Animation.spring(duration: 0.25, bounce: 0.35)
    /// Hover/selection feedback — ultra-responsive spring for interactive state changes.
    static let hoverFeedback = Animation.snappy(duration: 0.2)
    /// Skeleton shimmer — continuous linear sweep for loading placeholders.
    static let shimmer = Animation.linear(duration: 1.2).repeatForever(autoreverses: false)
    /// Skeleton pulse — continuous ease-in-out fade for loading placeholders.
    static let skeletonPulse = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    /// Progress bar — fast linear fill for time-sensitive progress indicators.
    static let progressBar = Animation.linear(duration: 0.06)
    /// Typewriter reveal — instant text update for character-by-character streaming.
    static let typewriterReveal = Animation.linear(duration: 0.05)
    /// Onboarding entrance — slow fade for ambient background elements.
    static let onboardingAmbient = Animation.easeOut(duration: 1.8)
    /// Onboarding reveal — smooth fade-out for text elements appearing in sequence.
    static let onboardingReveal = Animation.easeOut(duration: 0.5)
    /// Onboarding short reveal — quick fade for secondary text elements.
    static let onboardingRevealShort = Animation.easeOut(duration: 0.4)
    /// Onboarding transition — crossfade for post-sign-in view swap.
    static let onboardingTransition = Animation.smooth(duration: 0.35)
    /// Onboarding card entrance — heavier spring for the glass card scaling up.
    static let onboardingCardEntrance = Animation.spring(response: 0.7, dampingFraction: 0.8)
    /// Onboarding icon bounce — underdamped spring for dramatic helmet drop-in with rotation.
    static let onboardingIconBounce = Animation.spring(response: 0.7, dampingFraction: 0.55)
    /// Onboarding button entrance — snappier spring for the sign-in button appearing.
    static let onboardingButtonEntrance = Animation.spring(response: 0.5, dampingFraction: 0.8)
    /// Onboarding orb convergence — smooth ease-out for orbs returning to center during sign-in.
    static let onboardingOrbConverge = Animation.easeOut(duration: 0.5)
    /// Orb drift — long looping ease for ambient floating orb movement.
    static func orbDrift(duration: Double, delay: Double = 0) -> Animation {
        .easeInOut(duration: duration).repeatForever(autoreverses: true).delay(delay)
    }
}

// MARK: - Opacity Tokens

enum OpacityToken {
    /// Disabled controls, inactive elements
    static let disabled: CGFloat = 0.5
    /// Secondary foregrounds, muted icons
    static let secondary: CGFloat = 0.7
    /// Subtle background tints, hover highlights
    static let highlight: CGFloat = 0.08
    /// Badge/chip/tag backgrounds
    static let tag: CGFloat = 0.12
    /// Selection tint, interactive element backgrounds
    static let interactive: CGFloat = 0.15
    /// Divider lines, subtle borders
    static let divider: CGFloat = 0.5
    /// Modal/scrim overlays
    static let overlay: CGFloat = 0.45
}

// MARK: - Shimmer

enum ShimmerColor {
    /// Adaptive shimmer highlight — white flash in dark mode, dark flash in light mode.
    static let highlight = Color.adaptive(
        light: (red: 0.0, green: 0.0, blue: 0.0),
        dark:  (red: 1.0, green: 1.0, blue: 1.0)
    )
}

// MARK: - Z-Index

enum ZIndexToken {
    /// Toast notifications
    static let toast: Double = 5
    /// Slide panels, autocomplete dropdowns
    static let panel: Double = 10
    /// Command palette (above panels)
    static let palette: Double = 11
}

// MARK: - Scale Tokens

enum ScaleToken {
    /// Subtle hover lift on cards/buttons
    static let hover: CGFloat = 1.03
    /// Press feedback (slight shrink)
    static let press: CGFloat = 0.97
    /// Emphasized interaction (onboarding buttons)
    static let emphasis: CGFloat = 1.04
    /// Content entering view (scale-up from)
    static let enterFrom: CGFloat = 0.95
    /// Content exiting view (scale-down to)
    static let exitTo: CGFloat = 0.9
    /// Subtle hover lift on email rows (gentler than cards)
    static let rowHover: CGFloat = 1.01
}

// MARK: - Offset Tokens

enum OffsetToken {
    /// Micro nudge for subtle motion
    static let nudge: CGFloat = 4
    /// Pop-in animations, small reveals
    static let small: CGFloat = 12
}

// MARK: - Duration Tokens

enum DurationToken {
    /// Micro-feedback (hover, toggle)
    static let micro: CGFloat = 0.12
    /// Quick interaction (tab switch, badge)
    static let quick: CGFloat = 0.2
    /// Deliberate transitions (folder switch)
    static let deliberate: CGFloat = 0.3
    /// Stagger delay per item in lists
    static let stagger: CGFloat = 0.04
}

// MARK: - Typography

enum Typography {
    // Display
    static let titleLarge: Font = .title2.bold()

    // Title
    static let title: Font = .title3.bold()

    // Headline
    static let headline: Font = .headline

    // Subhead
    static let subhead: Font = .subheadline.weight(.medium)
    static let subheadRegular: Font = .subheadline
    static let subheadBold: Font = .subheadline.bold()
    static let subheadSemibold: Font = .subheadline.weight(.semibold)
    static let subheadMonospaced: Font = .subheadline.monospaced()

    // Body
    static let body: Font = .body
    static let bodyMedium: Font = .body.weight(.medium)
    static let bodyBold: Font = .body.bold()
    static let bodySemibold: Font = .body.weight(.semibold)

    // Callout
    static let callout: Font = .callout
    static let calloutMedium: Font = .callout.weight(.medium)
    static let calloutSemibold: Font = .callout.weight(.semibold)

    // Footnote
    static let footnote: Font = .footnote

    // Caption
    static let caption: Font = .caption.weight(.medium)
    static let captionRegular: Font = .caption
    static let captionSemibold: Font = .caption.weight(.semibold)
    static let captionSmall: Font = .caption2.weight(.semibold)
    static let captionSmallMedium: Font = .caption2.weight(.medium)
    static let captionSmallRegular: Font = .caption2
    /// Caption monospaced — for raw source display.
    static let captionMonospaced: Font = .caption.monospaced()
    /// Caption semibold monospaced — for header labels in raw views.
    static let captionSemiboldMonospaced: Font = .caption.weight(.semibold).monospaced()
    /// Caption2 medium monospaced — for file size displays.
    static let captionSmallMediumMonospaced: Font = .caption2.weight(.medium).monospaced()
    /// Caption2 bold — for label chips and tags.
    static let captionSmallBold: Font = .caption2.weight(.bold)

    // Micro — AI classification tags, tiny badges
    static let microTag: Font = .system(size: 10, weight: .medium)

    // Calendar-specific
    /// Event card title — semibold label inside timed event chips.
    static let calendarEventTitle: Font = .system(size: 13, weight: .semibold)
    /// Event card time — regular label inside timed event chips.
    static let calendarEventTime: Font = .system(size: 11, weight: .regular)
    /// Detail popover title — prominent semibold heading in CalendarEventDetailView.
    static let calendarDetailTitle: Font = .system(size: 18, weight: .semibold)
    /// Agenda event title — semibold label for event rows in the agenda list.
    static let calendarAgendaTitle: Font = .system(size: 14, weight: .semibold)
    /// Agenda time / metadata — small regular label for time strings and metadata chips.
    static let calendarAgendaTime: Font = .system(size: 12, weight: .regular)
    /// Mini month day cell — regular weight digit label for non-today cells.
    static let calendarMiniDay: Font = .system(size: 11, weight: .regular)
    /// Mini month weekday header — uppercase single-letter column headers.
    static let calendarMiniWeekday: Font = .system(size: 10, weight: .medium)
    /// Mini agenda widget event title — medium weight event name in sidebar widget.
    static let calendarMiniEventTitle: Font = .system(size: 12, weight: .medium)
    /// Mini agenda widget time — small regular time string in sidebar widget.
    static let calendarMiniEventTime: Font = .system(size: 11, weight: .regular)

    // Week view
    /// Week view "all-day" label in the time column — tiny regular label for accessibility column.
    static let calendarWeekAllDayLabel: Font = .system(size: 9, weight: .regular)
    /// Week view all-day event chip text — medium weight event name inside all-day chips.
    static let calendarWeekAllDayEvent: Font = .system(size: 10, weight: .medium)
    /// Week view weekday abbreviation header — medium weight column header above each day.
    static let calendarWeekdayAbbrev: Font = .system(size: 11, weight: .medium)
    /// Week view hour label — small regular label for each hour row in the time grid.
    static let calendarWeekHourLabel: Font = .system(size: 10, weight: .regular)

    // Display & Special
    /// Onboarding hero title — large bold display for app name.
    static let displayHero: Font = .system(size: 52, weight: .bold)
    /// Onboarding subtitle — medium weight body text for taglines.
    static let onboardingSubtitle: Font = .system(size: 15, weight: .medium)
    /// Empty state large icon — ultralight for decorative empty-state symbols.
    static let emptyStateIcon: Font = .system(size: 56, weight: .ultraLight)
    /// Empty state medium icon — light weight for secondary empty-state symbols.
    static let emptyStateMediumIcon: Font = .system(size: 36, weight: .light)
    /// Calendar event editor title — semibold heading for the event title field.
    static let calendarEditorTitle: Font = .system(size: 20, weight: .semibold)
    /// Tracker domain label — tiny text for blocked tracker names.
    static let trackerLabel: Font = .system(size: 10, weight: .regular)
    /// Tracker domain label medium — tiny medium text for tracker group icons.
    static let trackerLabelMedium: Font = .system(size: 10, weight: .medium)
}

// MARK: - Elevation

struct ElevationModifier: ViewModifier {
    let level: ElevationLevel
    @Environment(\.colorScheme) private var colorScheme

    enum ElevationLevel {
        /// Flat surface, no shadow
        case surface
        /// Subtle lift — cards, non-modal panels
        case raised
        /// Popover/tooltip level
        case transient
        /// Modal/sheet level
        case elevated
    }

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        switch level {
        case .surface:
            content
        case .raised:
            content.shadow(color: (isDark ? Color.white : .black).opacity(isDark ? 0.04 : 0.06), radius: 4, x: 0, y: 2)
        case .transient:
            content.shadow(color: (isDark ? Color.white : .black).opacity(isDark ? 0.08 : 0.12), radius: 12, x: 0, y: 4)
        case .elevated:
            content.shadow(color: (isDark ? Color.white : .black).opacity(isDark ? 0.12 : 0.18), radius: 20, x: 0, y: 8)
        }
    }
}

extension View {
    func elevation(_ level: ElevationModifier.ElevationLevel) -> some View {
        modifier(ElevationModifier(level: level))
    }
}

// MARK: - Destructive Action Style

struct DestructiveActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Typography.subhead)
            .foregroundStyle(SemanticColor.error)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(SemanticColor.error.opacity(0.1), in: .rect(cornerRadius: CornerRadius.sm))
    }
}

extension View {
    func destructiveActionStyle() -> some View {
        modifier(DestructiveActionStyle())
    }
}

// MARK: - Toolbar Icon Button

struct ToolbarIconButton: View {
    let icon: String
    let label: String
    var size: CGFloat = ButtonSize.md
    var font: Font = Typography.body
    var useGlass: Bool = false
    let action: () -> Void

    /// Minimum tap target per Apple HIG (44pt).
    private var hitSize: CGFloat { max(size, 44) }

    var body: some View {
        Group {
            if useGlass {
                Button(action: action) {
                    Image(systemName: icon)
                        .font(font)
                        .frame(width: hitSize, height: hitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.glass)
            } else {
                Button(action: action) {
                    Image(systemName: icon)
                        .font(font)
                        .frame(width: hitSize, height: hitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Floating Panel Style

struct FloatingPanelStyle: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .elevation(.transient)
    }
}

extension View {
    func floatingPanelStyle(cornerRadius: CGFloat = CornerRadius.md) -> some View {
        modifier(FloatingPanelStyle(cornerRadius: cornerRadius))
    }
}

// MARK: - Dropdown Panel Style

struct DropdownPanelStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let shadowBase: Color = isDark ? .white : .black
        content
            .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.md))
            .overlay(RoundedRectangle(cornerRadius: CornerRadius.md).strokeBorder(.separator, lineWidth: 1))
            .shadow(color: shadowBase.opacity(isDark ? 0.08 : 0.12), radius: 12, y: 6)
            .shadow(color: shadowBase.opacity(isDark ? 0.03 : 0.04), radius: 3, y: 2)
    }
}

extension View {
    func dropdownPanelStyle() -> some View {
        modifier(DropdownPanelStyle())
    }
}

// MARK: - Glass or Material Modifier

struct GlassOrMaterial<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    init(in shape: S, interactive: Bool = false) {
        self.shape = shape
        self.interactive = interactive
    }

    func body(content: Content) -> some View {
        if interactive {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    func glassOrMaterial<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(GlassOrMaterial(in: shape, interactive: interactive))
    }
}

// MARK: - Calendar Colors

/// Google Calendar event colorId palette (1–11) — adaptive light/dark variants.
/// Maps directly to the `colorId` field in the Google Calendar API.
enum CalendarColor {
    /// colorId 1 — Lavender
    static let lavender = Color.adaptive(
        light: (red: 0.475, green: 0.525, blue: 0.796),
        dark:  (red: 0.580, green: 0.624, blue: 0.876)
    )
    /// colorId 2 — Sage
    static let sage = Color.adaptive(
        light: (red: 0.200, green: 0.714, blue: 0.475),
        dark:  (red: 0.310, green: 0.820, blue: 0.565)
    )
    /// colorId 3 — Grape
    static let grape = Color.adaptive(
        light: (red: 0.557, green: 0.141, blue: 0.667),
        dark:  (red: 0.680, green: 0.270, blue: 0.780)
    )
    /// colorId 4 — Flamingo
    static let flamingo = Color.adaptive(
        light: (red: 0.902, green: 0.486, blue: 0.451),
        dark:  (red: 0.940, green: 0.600, blue: 0.565)
    )
    /// colorId 5 — Banana
    static let banana = Color.adaptive(
        light: (red: 0.965, green: 0.749, blue: 0.149),
        dark:  (red: 0.980, green: 0.820, blue: 0.330)
    )
    /// colorId 6 — Tangerine
    static let tangerine = Color.adaptive(
        light: (red: 0.957, green: 0.318, blue: 0.118),
        dark:  (red: 0.970, green: 0.450, blue: 0.260)
    )
    /// colorId 7 — Peacock
    static let peacock = Color.adaptive(
        light: (red: 0.012, green: 0.608, blue: 0.898),
        dark:  (red: 0.150, green: 0.710, blue: 0.950)
    )
    /// colorId 8 — Graphite
    static let graphite = Color.adaptive(
        light: (red: 0.380, green: 0.380, blue: 0.380),
        dark:  (red: 0.530, green: 0.530, blue: 0.530)
    )
    /// colorId 9 — Blueberry
    static let blueberry = Color.adaptive(
        light: (red: 0.247, green: 0.318, blue: 0.710),
        dark:  (red: 0.380, green: 0.450, blue: 0.840)
    )
    /// colorId 10 — Basil
    static let basil = Color.adaptive(
        light: (red: 0.043, green: 0.502, blue: 0.263),
        dark:  (red: 0.160, green: 0.640, blue: 0.370)
    )
    /// colorId 11 — Tomato
    static let tomato = Color.adaptive(
        light: (red: 0.835, green: 0.000, blue: 0.000),
        dark:  (red: 0.920, green: 0.200, blue: 0.200)
    )

    /// Returns the adaptive `Color` for a given Google Calendar API `colorId` (1–11).
    /// Falls back to `BrandColor.blue` for unknown or `nil` colorIds.
    static func color(forId colorId: Int?) -> Color {
        switch colorId {
        case 1:  lavender
        case 2:  sage
        case 3:  grape
        case 4:  flamingo
        case 5:  banana
        case 6:  tangerine
        case 7:  peacock
        case 8:  graphite
        case 9:  blueberry
        case 10: basil
        case 11: tomato
        default: BrandColor.blue
        }
    }

    /// Human-readable name for a given Google Calendar API `colorId` (1–11).
    static func name(forId colorId: Int?) -> String {
        switch colorId {
        case 1:  "Lavender"
        case 2:  "Sage"
        case 3:  "Grape"
        case 4:  "Flamingo"
        case 5:  "Banana"
        case 6:  "Tangerine"
        case 7:  "Peacock"
        case 8:  "Graphite"
        case 9:  "Blueberry"
        case 10: "Basil"
        case 11: "Tomato"
        default: "Default"
        }
    }

    /// Returns `.black` or `.white` depending on which provides better contrast against the
    /// resolved calendar color. Uses `NSColor` dynamic resolution so the result adapts to
    /// the current light/dark appearance automatically.
    static func contrastingForeground(forId colorId: Int?) -> Color {
        Color.contrastingForeground(for: NSColor(color(forId: colorId)))
    }
}

// MARK: - Calendar Layout

/// Layout constants for calendar views (week grid, day view, agenda, event cards).
enum CalendarLayout {
    /// Height of a single hour row in the week/day grid.
    static let hourRowHeight: CGFloat = 48
    /// Width of the time-label column on the leading edge.
    static let timeColumnWidth: CGFloat = 50
    /// Minimum height for a rendered event card (prevents cards collapsing to nothing).
    static let eventCardMinHeight: CGFloat = 24
    /// Leading colored border width on event cards.
    static let eventCardBorderWidth: CGFloat = 3
    /// Height of the current-time indicator line.
    static let currentTimeIndicatorHeight: CGFloat = 2
    /// Diameter of the dot at the start of the current-time indicator.
    static let currentTimeIndicatorDotSize: CGFloat = 8
    /// Fixed height for all-day event chips in the header band.
    static let allDayEventHeight: CGFloat = 22
    /// Tap-target size for individual day cells in the mini month picker.
    static let miniMonthDaySize: CGFloat = 28
    /// Maximum number of events shown inline in the mini agenda before a "more" link.
    static let miniAgendaMaxEvents: Int = 5

    // MARK: - Icon sizes (editor & detail views)

    /// Standard SF Symbol icon size for form row icons in the event editor and detail views.
    static let editorIconSize: CGFloat = 14
    /// Circular action icon size for add/remove reminder buttons in the editor.
    static let editorActionIconSize: CGFloat = 16
    /// Small icon size for dismiss/clear icons (xmark) in the editor.
    static let editorSmallIconSize: CGFloat = 11
    /// Disclosure chevron icon size for calendar/account picker rows in the editor.
    static let editorChevronSize: CGFloat = 12
    /// Close button icon size for the dismiss control in CalendarEventDetailView.
    static let detailCloseIconSize: CGFloat = 18
    /// Small icon size for inline metadata icons (repeat badge) in the detail view.
    static let detailSmallIconSize: CGFloat = 11
    /// Meeting/conference icon size for the Join Meeting row in the detail view.
    static let detailMeetingIconSize: CGFloat = 13

    // MARK: - Month View

    /// Maximum number of event chips shown per day cell in month view before "+N more".
    static let monthViewMaxEventsPerCell: Int = 3
    /// Height of compact event chips in month view.
    static let monthEventChipHeight: CGFloat = 18
    /// Height reserved for multi-day spanning bars per stacking row.
    static let monthSpanningBarHeight: CGFloat = 20
    /// Maximum spanning bar rows per week row.
    static let monthMaxSpanningRows: Int = 3

    // MARK: - Layout calculations

    /// Y-position for a given time in the day/week grid.
    /// Convenience overload — computes `startOfDay` internally.
    static func yPosition(for date: Date) -> CGFloat {
        yPosition(for: date, startOfDay: Calendar.current.startOfDay(for: date))
    }

    /// Y-position using a pre-computed `startOfDay` to avoid repeated `Calendar.current` calls.
    /// Prefer this overload in render loops where multiple events share the same day.
    static func yPosition(for date: Date, startOfDay: Date) -> CGFloat {
        let secondsSinceMidnight = date.timeIntervalSince(startOfDay)
        return CGFloat(secondsSinceMidnight / 3600.0) * hourRowHeight
    }

    /// Height for an event spanning from `start` to `end`.
    static func eventHeight(start: Date, end: Date, clampToMinHeight: Bool = false) -> CGFloat {
        let duration = end.timeIntervalSince(start)
        let height = CGFloat(duration / 3600.0) * hourRowHeight
        return clampToMinHeight ? max(height, eventCardMinHeight) : height
    }

    /// Precomputed hour labels (0..<24) for day/week time grids. Index 0 is empty (midnight row hidden).
    static let hourLabels: [String] = (0..<24).map { hour in
        guard hour != 0 else { return "" }
        let components = DateComponents(hour: hour)
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formattedCalendarHour
    }
}

// MARK: - Calendar Semantic Colors

/// Semantic colors for calendar UI — adapts to light/dark automatically.
enum CalendarSemanticColor {
    /// Current-time indicator — coral/red accent matching `BrandColor.coral`.
    static let currentTimeIndicator = BrandColor.coral
    /// Today highlight — brand blue at 3% opacity for column background tints.
    static let todayHighlight = BrandColor.blue.opacity(0.03)
    /// Today header circle — solid brand blue for the date number badge.
    static let todayHeaderCircle = BrandColor.blue
    /// Today header text — contrasting foreground on the today circle.
    static let todayHeaderText = Color.contrastingForeground(for: NSColor(BrandColor.blue))
    /// Event card background — apply `.opacity(0.15)` to the event's calendar color.
    static let eventCardBackgroundOpacity: CGFloat = 0.15
    /// Weekend column dimming opacity — subtle desaturation of Saturday/Sunday columns.
    static let weekendColumnOpacity: CGFloat = 0.55

    // MARK: - Month View

    /// Month view day cell hover — subtle glass tint.
    static let monthCellHover = BrandColor.blue.opacity(0.10)
    /// Month view overflow days (prev/next month) — reduced opacity for day numbers.
    static let monthOverflowDayOpacity: CGFloat = 0.35
}

// MARK: - Haptic Feedback

@MainActor
enum VikHaptic {
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }

    static func generic() { perform(.generic) }
    static func levelChange() { perform(.levelChange) }
}

// MARK: - Contrast-Aware Foreground

extension Color {
    /// Returns a foreground color (white or black) that contrasts well with this background.
    static func contrastingForeground(for nsColor: NSColor) -> Color {
        let rgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.55 ? .black : .white
    }
}

// MARK: - Pointer Cursor

extension View {
    /// Sets the macOS cursor to a pointing hand on hover for clickable elements.
    func pointingHandCursor() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

