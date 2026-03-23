import SwiftUI

struct FilterEditorView: View {
    let viewModel: FiltersViewModel
    let onSave: (GmailFilter) -> Void
    var prefillFrom: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var from = ""
    @State private var to = ""
    @State private var subject = ""
    @State private var query = ""
    @State private var hasAttachment = false
    @State private var shouldArchive = false
    @State private var shouldMarkRead = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var showDiscardAlert = false

    private var hasChanges: Bool {
        !from.isEmpty || !to.isEmpty || !subject.isEmpty || !query.isEmpty
            || hasAttachment || shouldArchive || shouldMarkRead
    }

    var body: some View {
        Form {
            Section("Match criteria") {
                TextField("From", text: $from)
                TextField("To", text: $to)
                TextField("Subject contains", text: $subject)
                TextField("Has words", text: $query)
                Toggle("Has attachment", isOn: $hasAttachment)
            }
            Section("Actions") {
                Toggle("Skip Inbox (Archive)", isOn: $shouldArchive)
                Toggle("Mark as Read", isOn: $shouldMarkRead)
            }
            if let error {
                Text(error)
                    .foregroundStyle(SemanticColor.error)
                    .font(Typography.captionRegular)
                    .onAppear {
                        AccessibilityNotification.Announcement(error).post()
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 350)
        .task { if !prefillFrom.isEmpty { from = prefillFrom } }
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog(
            "Discard Changes?",
            isPresented: $showDiscardAlert,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if hasChanges {
                        showDiscardAlert = true
                    } else {
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Creating\u{2026}")
                        }
                    } else {
                        Text("Create")
                    }
                }
                .disabled(isSaving || (from.isEmpty && to.isEmpty && subject.isEmpty && query.isEmpty))
                .opacity((isSaving || (from.isEmpty && to.isEmpty && subject.isEmpty && query.isEmpty)) ? OpacityToken.disabled : 1.0)
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let criteria = GmailFilter.FilterCriteria(
            from: from.isEmpty ? nil : from,
            to: to.isEmpty ? nil : to,
            subject: subject.isEmpty ? nil : subject,
            query: query.isEmpty ? nil : query,
            hasAttachment: hasAttachment ? true : nil
        )
        var removeLabelIds: [String] = []
        if shouldArchive { removeLabelIds.append(GmailSystemLabel.inbox) }
        if shouldMarkRead { removeLabelIds.append(GmailSystemLabel.unread) }
        let action = GmailFilter.FilterAction(removeLabelIds: removeLabelIds.isEmpty ? nil : removeLabelIds)
        do {
            let filter = try await viewModel.createFilter(criteria: criteria, action: action)
            onSave(filter)
            dismiss()
        } catch {
            self.error = "Failed to create filter"
        }
    }
}
