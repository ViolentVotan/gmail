import SwiftUI

/// Overlay that shows undo, offline, and general toast notifications.
///
/// These `@Observable` singletons are UI infrastructure (overlay state managers),
/// not business-logic services. Direct access is an acceptable exception to the
/// "no service singletons in views" rule per architecture guidelines.
struct UnifiedToastLayer: View {
    private var network = NetworkMonitor.shared
    private var toastMgr = ToastManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer()

            // Priority 1: Undo toast (actionable, time-sensitive)
            UndoPresenceView(reduceMotion: reduceMotion)

            // Priority 2: Offline indicator (persistent status)
            if network.isConnected == false {
                OfflineToastCard()
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: ScaleToken.enterFrom)))
                    .padding(.bottom, Spacing.xxl)
            }
            // Priority 3: General toasts (ephemeral)
            else if let toast = toastMgr.currentToast {
                GeneralToastCard(toast: toast)
                    .id(toast.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: ScaleToken.enterFrom)))
                    .padding(.bottom, Spacing.xxl)
            }
        }
        .animation(reduceMotion ? nil : VikAnimation.springDefault, value: network.isConnected)
        .animation(reduceMotion ? nil : VikAnimation.springDefault, value: toastMgr.currentToast?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Undo Presence View

/// Isolates all `UndoActionManager` observation to this subtree.
/// `UnifiedToastLayer` does not observe `undoMgr` directly, so its body
/// is not re-evaluated on every 250ms progress tick.
fileprivate struct UndoPresenceView: View {
    let reduceMotion: Bool
    private var undoMgr = UndoActionManager.shared

    fileprivate init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        Group {
            if let action = undoMgr.currentAction {
                UndoToastCard(action: action)
                    .id(action.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: ScaleToken.enterFrom)))
                    .padding(.bottom, Spacing.xxl)
            }
        }
        .animation(reduceMotion ? nil : VikAnimation.springDefault, value: undoMgr.currentAction?.id)
        .sensoryFeedback(.warning, trigger: undoMgr.currentAction != nil)
    }
}

// MARK: - Undo Toast Card

private struct UndoToastCard: View {
    let action: PendingUndoAction
    @AppStorage(UserDefaultsKey.undoDuration) private var undoDuration = 5
    @State private var timeRemaining: Int = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(action.label)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Button("Undo") { UndoActionManager.shared.undo() }
                    .font(Typography.bodySemibold)
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)

                Text("\(timeRemaining)s")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .trailing)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)

            UndoProgressBar(undoDuration: undoDuration, onSecondTick: { seconds in
                timeRemaining = seconds
            })
        }
        .transientGlass()
        .frame(width: 320)
    }
}

// MARK: - Undo Progress Bar

/// Reads `undoMgr.progress` in isolation so the 250ms animation ticks
/// do not invalidate `UndoToastCard.body` or any ancestor.
/// Fires `onSecondTick` only when the integer-second countdown changes.
fileprivate struct UndoProgressBar: View {
    let undoDuration: Int
    let onSecondTick: (Int) -> Void
    fileprivate var undoMgr = UndoActionManager.shared

    fileprivate init(undoDuration: Int, onSecondTick: @escaping (Int) -> Void) {
        self.undoDuration = undoDuration
        self.onSecondTick = onSecondTick
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.separator)
            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .scaleEffect(x: undoMgr.progress, y: 1, anchor: .leading)
                .animation(VikAnimation.progressBar, value: undoMgr.progress)
        }
        .frame(height: 3)
        .onAppear {
            onSecondTick(max(1, Int(ceil(undoMgr.progress * Double(undoDuration)))))
        }
        .onChange(of: undoMgr.progress) { oldProgress, newProgress in
            let oldSeconds = max(1, Int(ceil(oldProgress * Double(undoDuration))))
            let newSeconds = max(1, Int(ceil(newProgress * Double(undoDuration))))
            if newSeconds != oldSeconds {
                onSecondTick(newSeconds)
            }
        }
    }
}

// MARK: - Offline Toast Card

private struct OfflineToastCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(Typography.bodyMedium)
                .foregroundStyle(SemanticColor.warning)
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
        case .success: SemanticColor.success
        case .error:   SemanticColor.error
        case .info:    Color.accentColor
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
