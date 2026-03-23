import SwiftUI

struct SyncBubbleView: View {
    let phase: SyncPhase
    var isCompact = false
    var onRefresh: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var isTappable: Bool {
        switch phase {
        case .idle, .error: true
        default: false
        }
    }

    var body: some View {
        if isCompact {
            compactBody
        } else {
            fullBody
        }
    }

    private var compactBody: some View {
        Button(action: onRefresh) {
            icon
                .font(Typography.captionRegular)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!isTappable)
        .help(accessibilityText)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isTappable ? "Double-tap to sync mail" : "")
    }

    private var fullBody: some View {
        Button(action: onRefresh) {
            HStack(spacing: Spacing.sm) {
                icon
                label
            }
            .font(Typography.captionRegular)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(!isTappable)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : VikAnimation.springSnappy) {
                isHovered = hovering
            }
        }
        .help(isTappable ? "Click to sync" : "")
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isTappable ? "Double-tap to sync mail" : "")
    }

    // MARK: - Icon

    @ViewBuilder
    private var icon: some View {
        switch phase {
        case .idle:
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(isHovered ? .secondary : .tertiary)
                .symbolEffect(.breathe, isActive: !isHovered)
                .contentTransition(.symbolEffect(.replace))
        case .syncing, .initialSync, .bodyPrefetch:
            ProgressView()
                .controlSize(.small)
                .tint(.accentColor)
        case .success:
            Image(systemName: "checkmark")
                .foregroundStyle(SemanticColor.success)
                .fontWeight(.semibold)
                .contentTransition(.symbolEffect(.replace))
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(SemanticColor.error)
                .fontWeight(.semibold)
                .symbolEffect(.pulse, isActive: !isHovered)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    // MARK: - Label

    @ViewBuilder
    private var label: some View {
        switch phase {
        case .idle(let lastSynced):
            if let lastSynced {
                Text("Last synced: \(lastSynced, format: .relative(presentation: .named))")
                    .foregroundStyle(isHovered ? .secondary : .tertiary)
                    .contentTransition(.interpolate)
            } else {
                Text("Sync now")
                    .foregroundStyle(isHovered ? .secondary : .tertiary)
                    .contentTransition(.interpolate)
            }
        case .syncing(let remaining):
            if let remaining {
                Text("\(remaining) remaining")
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            } else {
                Text("Syncing")
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
        case .initialSync(let synced, let estimated):
            if estimated > 0 {
                Text("Syncing \(synced) / ~\(estimated)")
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            } else {
                Text("Preparing sync…")
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
        case .bodyPrefetch(let remaining):
            Text("\(remaining) bodies remaining")
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        case .success:
            Text("Synced")
                .foregroundStyle(.secondary)
        case .error(let message):
            Text(message)
                .foregroundStyle(SemanticColor.error)
        }
    }

    // MARK: - Accessibility

    private var accessibilityText: String {
        switch phase {
        case .idle(let lastSynced):
            if let lastSynced {
                "Refresh mail. Last synced \(lastSynced.formatted(.relative(presentation: .named)))."
            } else {
                "Sync mail now."
            }
        case .syncing(let remaining):
            if let remaining {
                "Syncing mail. \(remaining) remaining."
            } else {
                "Syncing mail."
            }
        case .initialSync(let synced, let estimated):
            estimated > 0 ? "Syncing mail. \(synced) of \(estimated)." : "Preparing to sync mail."
        case .bodyPrefetch(let remaining):
            "Downloading message bodies. \(remaining) remaining."
        case .success:
            "Mail synced."
        case .error(let message):
            "Sync failed: \(message). Double-tap to retry."
        }
    }
}
