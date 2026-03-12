import SwiftUI
import AppKit

// MARK: - Pull-to-Refresh Detector

struct PullToRefreshDetector: NSViewRepresentable {
    @Binding var isRefreshing: Bool
    let onRefresh: (() async -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard let scrollView = view.enclosingScrollView else { return }
            context.coordinator.attach(to: scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onRefresh = onRefresh
        context.coordinator.isRefreshingBinding = $isRefreshing
        context.coordinator.isRefreshing = isRefreshing
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        var isRefreshing = false
        var onRefresh: (() async -> Void)?
        var isRefreshingBinding: Binding<Bool>?
        private var didPassThreshold = false

        func attach(to sv: NSScrollView) {
            guard scrollView == nil else { return }
            scrollView = sv
            sv.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: sv.contentView
            )
        }

        @objc func boundsChanged() {
            guard let sv = scrollView, !isRefreshing else { return }
            let overscroll = -(sv.contentView.bounds.origin.y + sv.contentInsets.top)
            if overscroll > 60 && !didPassThreshold {
                didPassThreshold = true
                triggerRefresh()
            } else if overscroll <= 0 {
                didPassThreshold = false
            }
        }

        private func triggerRefresh() {
            isRefreshing = true
            isRefreshingBinding?.wrappedValue = true
            let refreshAction = onRefresh
            Task { @MainActor in
                let start = ContinuousClock.now
                await refreshAction?()
                let elapsed = ContinuousClock.now - start
                let remaining = Duration.milliseconds(800) - elapsed
                if remaining > .zero { try? await Task.sleep(for: remaining) }
                self.isRefreshing = false
                self.isRefreshingBinding?.wrappedValue = false
                self.didPassThreshold = false
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
