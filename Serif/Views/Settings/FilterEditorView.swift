import SwiftUI

struct FilterEditorView: View {
    let accountID: String
    let onSave: (GmailFilter) -> Void

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
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 350)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { Task { await save() } }
                    .disabled(isSaving || (from.isEmpty && to.isEmpty && subject.isEmpty && query.isEmpty))
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
        if shouldArchive { removeLabelIds.append("INBOX") }
        if shouldMarkRead { removeLabelIds.append("UNREAD") }
        let action = GmailFilter.FilterAction(removeLabelIds: removeLabelIds.isEmpty ? nil : removeLabelIds)
        do {
            let filter = try await GmailFilterService.shared.createFilter(criteria: criteria, action: action, accountID: accountID)
            onSave(filter)
            dismiss()
        } catch {
            self.error = "Failed to create filter"
        }
    }
}
