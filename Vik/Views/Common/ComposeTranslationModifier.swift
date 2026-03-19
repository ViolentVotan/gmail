import SwiftUI
import Translation

struct ComposeTranslationModifier: ViewModifier {
    @Binding var htmlBody: String
    var editorState: WebRichTextEditorState
    @State private var showTranslation = false
    @State private var translationSourceText = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: editorState.translationRequested) { _, requested in
                guard requested else { return }
                editorState.translationRequested = false
                translationSourceText = htmlBody.strippingHTML
                showTranslation = true
            }
            .translationPresentation(isPresented: $showTranslation, text: translationSourceText) { translated in
                guard !translated.isEmpty else { return }
                let html = translated.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "<p>\($0)</p>" }
                    .joined()
                editorState.setHTML(html)
                htmlBody = html
            }
    }
}

extension View {
    func composeTranslation(html: Binding<String>, editorState: WebRichTextEditorState) -> some View {
        modifier(ComposeTranslationModifier(htmlBody: html, editorState: editorState))
    }
}
