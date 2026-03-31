import SwiftUI

struct ScheduleSendButton: View {
    let onSend: () -> Void
    let onSchedule: (Date) -> Void
    let isSending: Bool

    @State private var showSchedulePicker = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSend) {
                if isSending {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Text("Send")
                }
            }
            .help("Send")
            .accessibilityLabel(isSending ? "Sending email" : "Send email")
            .accessibilityValue(isSending ? "In progress" : "")
            .disabled(isSending)

            Divider()
                .frame(height: 20)
                .padding(.horizontal, Spacing.xxs)

            Button {
                showSchedulePicker = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(Typography.captionSmallRegular)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Schedule send options")
            .accessibilityHint("Opens a picker to schedule when this email will be sent")
            .popover(isPresented: $showSchedulePicker) {
                SnoozePickerView(title: "Schedule for...") { date in
                    showSchedulePicker = false
                    onSchedule(date)
                }
            }
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }
}
