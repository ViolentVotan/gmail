import SwiftUI

/// Overlay that shows undo, offline, and general toast notifications.
///
/// These `@Observable` singletons are UI infrastructure (overlay state managers),
/// not business-logic services. Direct access is an acceptable exception to the
/// "no service singletons in views" rule per architecture guidelines.
struct UnifiedToastLayer: View {
    private var network = NetworkMonitor.shared
    private var undoMgr = UndoActionManager.shared
    private var toastMgr = ToastManager.shared

    var body: some View {
        VStack {
            Spacer()

            // Priority 1: Undo toast (actionable, time-sensitive)
            if let action = undoMgr.currentAction {
                UndoToastCard(action: action)
                    .id(action.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, Spacing.xxl)
            }
            // Priority 2: Offline indicator (persistent status)
            else if !network.isConnected {
                OfflineToastCard()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, Spacing.xxl)
            }
            // Priority 3: General toasts (ephemeral)
            else if let toast = toastMgr.currentToast {
                GeneralToastCard(toast: toast)
                    .id(toast.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, Spacing.xxl)
            }
        }
        .animation(SerifAnimation.springDefault, value: undoMgr.currentAction?.id)
        .animation(SerifAnimation.springDefault, value: network.isConnected)
        .animation(SerifAnimation.springDefault, value: toastMgr.currentToast?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(undoMgr.currentAction != nil)
    }
}

// MARK: - Undo Toast Card

private struct UndoToastCard: View {
    let action: PendingUndoAction
    var undoMgr = UndoActionManager.shared

    var body: some View {
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

            ZStack(alignment: .leading) {
                Rectangle().fill(.separator)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.7))
                    .scaleEffect(x: undoMgr.progress, y: 1, anchor: .leading)
                    .animation(.linear(duration: 0.06), value: undoMgr.progress)
            }
            .frame(height: 3)
        }
        .transientGlass()
        .frame(width: 320)
    }
}

// MARK: - Offline Toast Card

private struct OfflineToastCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(Typography.bodyMedium)
                .foregroundStyle(.orange)
            Text("No internet connection")
                .font(Typography.bodyMedium)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .transientGlass()
        .frame(width: 320)
    }
}

// MARK: - General Toast Card

private struct GeneralToastCard: View {
    let toast: ToastMessage
    var toastMgr = ToastManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(toast.type))
                .font(Typography.bodyMedium)
                .foregroundStyle(iconColor(toast.type))
            Text(toast.message)
                .font(Typography.bodyMedium)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .transientGlass()
        .frame(width: 320)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            AccessibilityNotification.Announcement(toast.message).post()
        }
    }

    private func iconName(_ type: ToastType) -> String {
        switch type {
        case .success: "checkmark.circle.fill"
        case .error:   "xmark.circle.fill"
        case .info:    "info.circle.fill"
        }
    }

    private func iconColor(_ type: ToastType) -> Color {
        switch type {
        case .success: .green
        case .error:   .red
        case .info:    .blue
        }
    }
}

// MARK: - Shared Glass Modifier

struct TransientGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.md))
            .elevation(.transient)
    }
}

extension View {
    func transientGlass() -> some View {
        modifier(TransientGlassModifier())
    }
}
