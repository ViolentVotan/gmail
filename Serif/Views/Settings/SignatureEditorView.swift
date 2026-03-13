import SwiftUI

struct SignatureEditorView: View {
    let alias: GmailSendAs
    let accountID: String
    var onSave: ((GmailSendAs) -> Void)?
    var onUpdateSignature: ((String, String, String) async throws -> GmailSendAs)?

    @StateObject private var editorState = WebRichTextEditorState()
    @State private var htmlContent: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                FormattingToolbar(state: editorState)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            editorArea
            if let error = errorMessage {
                errorBanner(error)
            }
        }
        .frame(width: 560, height: 420)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
        .onAppear {
            htmlContent = alias.signature ?? ""
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Signature")
                    .font(Typography.headline)
                    .foregroundStyle(.primary)
                Text(alias.sendAsEmail)
                    .font(Typography.footnote)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(Typography.callout)
            saveButton
        }
        .padding(16)
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button {
            save()
        } label: {
            HStack(spacing: 5) {
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }
                Text(isSaving ? "Saving…" : "Save")
                    .font(Typography.callout)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    // MARK: - Editor

    private var editorArea: some View {
        WebRichTextEditor(
            state: editorState,
            htmlContent: $htmlContent,
            placeholder: "Enter your signature…"
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(Typography.footnote)
            Text(message)
                .font(Typography.footnote)
                .foregroundStyle(.red)
            Spacer()
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(Typography.captionSmall)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    // MARK: - Save Action

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                guard let updated = try await onUpdateSignature?(alias.sendAsEmail, htmlContent, accountID) else {
                    errorMessage = "Failed to save: no response"
                    isSaving = false
                    return
                }
                onSave?(updated)
                dismiss()
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
