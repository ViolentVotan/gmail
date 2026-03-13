import SwiftUI

// MARK: - Shared glass modifier for transient toasts

private struct TransientGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.md))
                .elevation(.transient)
        } else {
            content
                .background(RoundedRectangle(cornerRadius: CornerRadius.md).fill(.regularMaterial))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
                .elevation(.transient)
        }
    }
}

private extension View {
    func transientGlass() -> some View {
        modifier(TransientGlassModifier())
    }
}

// MARK: - Offline Toast

struct OfflineToastView: View {
    private var network = NetworkMonitor.shared

    var body: some View {
        VStack {
            Spacer()
            if !network.isConnected {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.slash")
                        .font(Typography.bodyMedium)
                        .foregroundColor(.orange)
                    Text("No internet connection")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .transientGlass()
                .frame(width: 320)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, Spacing.xxl)
            }
        }
        .animation(SerifAnimation.springDefault, value: network.isConnected)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: - Undo Toast

struct UndoToastView: View {
    private var undoMgr = UndoActionManager.shared

    var body: some View {
        VStack {
            Spacer()
            if let action = undoMgr.currentAction {
                toastCard(action)
                    .id(action.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, Spacing.xxl)
            }
        }
        .animation(SerifAnimation.springDefault, value: undoMgr.currentAction?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(undoMgr.currentAction != nil)
    }

    private func toastCard(_ action: PendingUndoAction) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(action.label)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Button("Undo") { undoMgr.undo() }
                    .font(Typography.bodySemibold)
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)

                Text("\(max(1, Int(ceil(undoMgr.timeRemaining))))s")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .trailing)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.separator)
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: geo.size.width * undoMgr.progress)
                        .animation(.linear(duration: 0.06), value: undoMgr.progress)
                }
            }
            .frame(height: 3)
        }
        .transientGlass()
        .frame(width: 320)
    }
}
