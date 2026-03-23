import AppKit

extension NSWorkspace {
    /// Whether the user has enabled "Reduce motion" in System Settings → Accessibility → Display.
    /// Use this in ViewModels and actors where `@Environment(\.accessibilityReduceMotion)` is unavailable.
    @MainActor
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
