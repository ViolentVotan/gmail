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
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(isSending)

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 2)

            Menu {
                Button {
                    showSchedulePicker = true
                } label: {
                    Label("Schedule Send", systemImage: "calendar.badge.clock")
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .popover(isPresented: $showSchedulePicker) {
                SnoozePickerView(title: "Schedule for...") { date in
                    showSchedulePicker = false
                    onSchedule(date)
                }
            }
        }
    }
}
