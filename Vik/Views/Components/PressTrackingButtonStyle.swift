import SwiftUI

/// A button style that tracks press state via a binding.
/// Used across email rows, calendar event cards, and month chips
/// to drive scale/hover animations from `configuration.isPressed`.
struct PressTrackingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}
