import SwiftUI

struct SyncBubbleView: View {
    let phase: SyncPhase

    var body: some View {
        HStack(spacing: Spacing.sm) {
            icon
            label
        }
        .font(Typography.captionRegular)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Icon

    @ViewBuilder
    private var icon: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .syncing:
            ProgressView()
                .controlSize(.small)
                .tint(.accentColor)
        case .initialSync, .bodyPrefetch:
            ProgressView()
                .controlSize(.small)
                .tint(.accentColor)
        case .success:
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
                .fontWeight(.semibold)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .fontWeight(.semibold)
        }
    }

    // MARK: - Label

    @ViewBuilder
    private var label: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .syncing(let remaining):
            if let remaining {
                Text("\(remaining) remaining")
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            } else {
                Text("Syncing")
                    .foregroundStyle(.secondary)
            }
        case .initialSync(let synced, let estimated):
            Text("Syncing \(synced) / ~\(estimated)")
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        case .bodyPrefetch(let remaining):
            Text("\(remaining) bodies remaining")
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        case .success:
            Text("Synced")
                .foregroundStyle(.secondary)
        case .error(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }
}
