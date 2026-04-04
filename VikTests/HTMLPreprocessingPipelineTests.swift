import Testing
@testable import Vik

@Suite struct HTMLPreprocessingPipelineTests {
    @Test func preprocessesHTMLDeterministically() {
        let html = "<html><head><style>.x{}</style></head><body><p>Hello</p></body></html>"
        let r1 = HTMLPreprocessingPipeline.preprocess(html)
        let r2 = HTMLPreprocessingPipeline.preprocess(html)
        #expect(r1.preprocessedHTML == r2.preprocessedHTML)
        #expect(r1.sanitizedHTML == r2.sanitizedHTML)
        #expect(r1.originalHTML == r2.originalHTML)
        #expect(r1.quotedHTML == r2.quotedHTML)
        #expect(r1.version == HTMLPreprocessingPipeline.currentVersion)
    }

    @Test func stripsHeadPreservesStyles() {
        let html = "<html><head><style>body{color:red}</style></head><body><p>Content</p></body></html>"
        let result = HTMLPreprocessingPipeline.preprocess(html)
        // Style blocks are extracted from <head> and preserved for email layout
        #expect(result.preprocessedHTML.contains("body{color:red}"))
        #expect(!result.preprocessedHTML.contains("<head>"))
        #expect(result.preprocessedHTML.contains("Content"))
    }

    @Test func splitsQuotedContent() {
        let html = "<p>Original</p><div class=\"gmail_quote\">Quoted stuff</div>"
        let result = HTMLPreprocessingPipeline.preprocess(html)
        #expect(result.originalHTML.contains("Original"))
        #expect(result.quotedHTML != nil)
        #expect(result.quotedHTML?.contains("gmail_quote") == true)
    }

    @Test func handlesNilQuotedContent() {
        let html = "<p>Just a simple email</p>"
        let result = HTMLPreprocessingPipeline.preprocess(html)
        #expect(result.originalHTML.contains("simple email"))
        #expect(result.quotedHTML == nil)
    }

    @Test func handlesEmptyInput() {
        let result = HTMLPreprocessingPipeline.preprocess("")
        #expect(result.preprocessedHTML.isEmpty)
        #expect(result.sanitizedHTML.isEmpty)
        #expect(result.originalHTML.isEmpty)
        #expect(result.quotedHTML == nil)
    }

    @Test func versionMatchesCurrent() {
        let result = HTMLPreprocessingPipeline.preprocess("<p>test</p>")
        #expect(result.version == HTMLPreprocessingPipeline.currentVersion)
    }
}
