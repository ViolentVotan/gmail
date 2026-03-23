import SwiftUI

/// Shared bottom action bar used by both ComposeView and the expanded ReplyBarView.
///
/// Pass `onMinimize: nil` for standalone compose (hides the minimize button).
/// The discard and send buttons appear when `composeVM.hasUserContent` is true,
/// or always when `onMinimize` is nil (standalone compose always shows them).
struct ComposeActionBar: View {
    @Bindable var composeVM: ComposeViewModel
    let onMinimize: (() -> Void)?
    let onDiscard: () -> Void
    let onSend: () -> Void
    let onSchedule: (Date) -> Void
    let onAttach: () -> Void
    @Binding var sendHapticTrigger: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showSendControls: Bool {
        composeVM.hasUserContent || onMinimize == nil
    }

    var body: some View {
        HStack(spacing: 12) {
            if let onMinimize {
                Button(action: onMinimize) {
                    Image(systemName: "chevron.down")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: ButtonSize.lg, height: ButtonSize.lg)
                }
                .buttonStyle(.plain)
                .help("Minimize")
                .accessibilityLabel("Minimize reply")
                .keyboardShortcut(.escape, modifiers: [])
            }

            Button(action: onAttach) {
                Image(systemName: "paperclip")
                    .font(Typography.subheadRegular)
                    .foregroundStyle(.secondary)
                    .frame(width: ButtonSize.lg, height: ButtonSize.lg)
            }
            .buttonStyle(.plain)
            .help("Attach file")
            .accessibilityLabel("Attach file")

            Spacer()

            if showSendControls {
                Button(action: onDiscard) {
                    Text("Discard")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("Discard")
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))

                ScheduleSendButton(
                    onSend: onSend,
                    onSchedule: onSchedule,
                    isSending: composeVM.isSending
                )
                .disabled(composeVM.isSending)
                .opacity(composeVM.isSending ? OpacityToken.disabled : 1)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
                .accessibilityHint("Sends the email. Use the dropdown to schedule.")
                .sensoryFeedback(.success, trigger: sendHapticTrigger)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }
}
