import SwiftUI

struct SearchBarView: View {
    @Binding var text: String
    @Binding var focusTrigger: Bool
    @State private var isFocused = false

    init(text: Binding<String>, focusTrigger: Binding<Bool> = .constant(false)) {
        self._text = text
        self._focusTrigger = focusTrigger
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Typography.bodyMedium)
                .foregroundStyle(isFocused ? .secondary : .tertiary)

            NonAutoFocusTextField(text: $text, placeholder: "Search", focusTrigger: $focusTrigger, isFocused: $isFocused)
                .font(Typography.body)
                .foregroundStyle(.primary)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(
            isFocused ? .regular.interactive() : .regular,
            in: .capsule
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.4 : 0), lineWidth: 1.5)
        )
        .animation(VikAnimation.springSnappy, value: isFocused)
        .animation(VikAnimation.springSnappy, value: text.isEmpty)
    }
}

// MARK: - NSTextField wrapper that refuses initial first responder

struct NonAutoFocusTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var focusTrigger: Bool
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NoAutoFocusNSTextField {
        let field = NoAutoFocusNSTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = true
        return field
    }

    func updateNSView(_ nsView: NoAutoFocusNSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if focusTrigger {
            focusTrigger = false  // Reset synchronously to prevent duplicate tasks
            Task { @MainActor in
                nsView.programmaticFocus = true
                nsView.window?.makeFirstResponder(nsView)
                nsView.programmaticFocus = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: NonAutoFocusTextField
        init(_ parent: NonAutoFocusTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused = false
        }
    }
}

class NoAutoFocusNSTextField: NSTextField {
    var programmaticFocus = false

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if programmaticFocus {
            return super.becomeFirstResponder()
        }
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown || event.type == .keyDown {
            return super.becomeFirstResponder()
        }
        return false
    }
}
