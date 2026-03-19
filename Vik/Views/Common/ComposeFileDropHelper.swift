import SwiftUI

/// Shared file-drop routing logic for compose surfaces.
enum ComposeFileDropHelper {
    @MainActor
    static func handle(
        url: URL,
        composeVM: ComposeViewModel,
        editorState: WebRichTextEditorState,
        attachments: inout [URL]
    ) {
        switch composeVM.handleFileDrop(url) {
        case .image:
            editorState.insertImage(from: url)
        case .attachment:
            attachments.append(url)
        case .unsupported(let message):
            composeVM.showToast(message, type: .error)
        }
    }
}
