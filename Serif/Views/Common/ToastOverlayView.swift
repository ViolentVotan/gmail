import SwiftUI

struct ToastOverlayView: View {
    private var toastMgr = ToastManager.shared

    var body: some View {
        VStack {
            Spacer()
            if let toast = toastMgr.currentToast {
                toastCard(toast)
                    .id(toast.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, Spacing.xxl)
            }
        }
        .animation(SerifAnimation.springDefault, value: toastMgr.currentToast?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func toastCard(_ toast: ToastMessage) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                toastContent(toast)
                    .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.md))
                    .elevation(.transient)
            } else {
                toastContent(toast)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(.regularMaterial)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
                    .elevation(.transient)
            }
        }
        .frame(width: 320)
    }

    private func toastContent(_ toast: ToastMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(toast.type))
                .font(Typography.bodyMedium)
                .foregroundColor(iconColor(toast.type))
            Text(toast.message)
                .font(Typography.bodyMedium)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            if let toast = toastMgr.currentToast {
                AccessibilityNotification.Announcement(toast.message).post()
            }
        }
    }

    private func iconName(_ type: ToastType) -> String {
        switch type {
        case .success: return "checkmark.circle.fill"
        case .error:   return "xmark.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    private func iconColor(_ type: ToastType) -> Color {
        switch type {
        case .success: return .green
        case .error:   return .red
        case .info:    return .blue
        }
    }
}
