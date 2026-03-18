import SwiftUI

// MARK: - CalendarQuickAddView

/// A compact natural-language event creation panel.
/// Type a phrase like "Lunch tomorrow at noon" and submit to call the
/// Google Calendar quickAdd API.
struct CalendarQuickAddView: View {
    @State private var text = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?

    let accountID: String
    let calendarId: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(.secondary)
                    .imageScale(.medium)

                TextField("Add event — e.g. \"Lunch tomorrow at noon\"", text: $text)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .onSubmit { submit() }

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: submit) {
                        Image(systemName: "return")
                    }
                    .buttonStyle(.borderless)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(Spacing.md)

            if let errorMessage {
                Text(errorMessage)
                    .font(Typography.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.sm)
            }
        }
        .floatingPanelStyle(cornerRadius: CornerRadius.md)
        .frame(width: 420)
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    // MARK: - Actions

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessing else { return }

        isProcessing = true
        errorMessage = nil

        Task {
            do {
                _ = try await CalendarEventService.shared.quickAdd(
                    calendarId: calendarId,
                    text: trimmed,
                    accountID: accountID
                )
                onDismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }
}

// MARK: - Preview

#Preview {
    CalendarQuickAddView(
        accountID: "preview@example.com",
        calendarId: "primary",
        onDismiss: {}
    )
    .padding()
}
