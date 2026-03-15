import Foundation
import Observation

enum ToastType: Sendable {
    case success, error, info
}

struct ToastMessage: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
    let type: ToastType

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

@Observable
@MainActor
final class ToastManager {
    static let shared = ToastManager()
    private init() {}

    var currentToast: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    func show(message: String, type: ToastType = .info, duration: Double = 3.5) {
        dismissTask?.cancel()
        currentToast = ToastMessage(message: message, type: type)
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            currentToast = nil
        }
    }
}
