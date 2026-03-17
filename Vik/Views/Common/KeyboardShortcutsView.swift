import SwiftUI
@preconcurrency import AppKit
import WebKit

/// Invisible view that captures global keyboard shortcuts.
/// Cmd+A, Cmd+Z, and Cmd+F are handled via NSEvent monitor to respect the responder chain
/// (text fields/editors get priority over global app shortcuts).
struct KeyboardShortcutsView: View {
    var coordinator: AppCoordinator

    var body: some View {
        Group {
            Button("") { coordinator.panelCoordinator.closeAll() }
                .keyboardShortcut(.escape, modifiers: []).disabled(!coordinator.panelCoordinator.isAnyOpen)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .background(KeyboardEventMonitor(coordinator: coordinator))
    }
}

// MARK: - Responder-aware keyboard monitor

/// Uses NSEvent.addLocalMonitorForEvents to intercept key events
/// while respecting the first responder chain (text fields get native Cmd+A/Z/F).
private struct KeyboardEventMonitor: NSViewRepresentable {
    let coordinator: AppCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.coordinator = coordinator
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator(coordinator: coordinator) }

    @MainActor
    class Coordinator {
        var coordinator: AppCoordinator
        nonisolated(unsafe) private var monitor: Any?

        init(coordinator: AppCoordinator) {
            self.coordinator = coordinator
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Extract event data before crossing into MainActor (NSEvent isn't Sendable)
                let keyCode = event.keyCode
                let modifiers = event.modifierFlags
                let chars = event.charactersIgnoringModifiers
                let consumed = MainActor.assumeIsolated {
                    self.handleKeyDown(keyCode: keyCode, modifiers: modifiers, chars: chars)
                }
                return consumed ? nil : event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private var isTextInputFocused: Bool {
            guard let responder = NSApp.keyWindow?.firstResponder else { return false }
            if responder is NSTextView || responder is NSTextField { return true }
            // WKWebView uses an internal NSView subclass as first responder;
            // walk up the view hierarchy to detect it.
            var view = responder as? NSView
            while let v = view {
                if v is WKWebView { return true }
                view = v.superview
            }
            return false
        }

        /// Returns `true` if the event was consumed and should not propagate.
        private func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, chars: String?) -> Bool {
            let coord = coordinator

            // Escape — close any open panel (takes priority over everything)
            if keyCode == 53 {
                if coord.panelCoordinator.isAnyOpen {
                    coord.panelCoordinator.closeAll()
                    return true
                }
            }

            guard modifiers.contains(.command),
                  !modifiers.contains(.shift) else { return false }

            switch chars {
            case "a":
                if isTextInputFocused { return false } // let native select-all handle it
                coord.selectAllEmails()
                return true

            case "z":
                if isTextInputFocused { return false } // let native undo handle it
                UndoActionManager.shared.undo()
                return true

            case "f":
                if isTextInputFocused { return false } // let native find handle it
                coord.searchFocusTrigger = true
                return true

            default:
                return false
            }
        }
    }
}
