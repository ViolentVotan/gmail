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
                    .padding(.bottom, 28)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastMgr.currentToast?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func toastCard(_ toast: ToastMessage) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                toastContent(toast)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
            } else {
                toastContent(toast)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.regularMaterial)
                            .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 4)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(width: 320)
    }

    private func toastContent(_ toast: ToastMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(toast.type))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(iconColor(toast.type))
            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
