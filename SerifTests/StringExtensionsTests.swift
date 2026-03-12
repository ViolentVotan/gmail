import Testing
@testable import Serif

@Suite struct StringExtensionsTests {

    // MARK: - strippingHTML

    @Test func strippingHTML_RemovesTags() {
        let html = "<p>Hello <b>World</b></p>"
        let result = html.strippingHTML
        #expect(result.contains("Hello"))
        #expect(result.contains("World"))
        #expect(!result.contains("<b>"))
        #expect(!result.contains("</b>"))
        #expect(!result.contains("<p>"))
    }

    @Test func strippingHTML_ReplacesBreaksWithNewlines() {
        let html = "Line1<br>Line2<br/>Line3"
        let result = html.strippingHTML
        #expect(result.contains("Line1"))
        #expect(result.contains("Line2"))
        #expect(result.contains("Line3"))
    }

    @Test func strippingHTML_DecodesEntities() {
        let html = "&lt;hello&gt; &amp; &quot;world&quot; &#39;test&#39;"
        let result = html.strippingHTML
        #expect(result.contains("<hello>"))
        #expect(result.contains("& \"world\""))
        #expect(result.contains("'test'"))
    }

    @Test func strippingHTML_RemovesStyleBlocks() {
        let html = "<style>body { color: red; }</style><p>Content</p>"
        let result = html.strippingHTML
        #expect(!result.contains("color"))
        #expect(result.contains("Content"))
    }

    @Test func strippingHTML_RemovesScriptBlocks() {
        let html = "<script>alert('xss')</script><p>Safe</p>"
        let result = html.strippingHTML
        #expect(!result.contains("alert"))
        #expect(result.contains("Safe"))
    }

    @Test func strippingHTML_ReplacesNbsp() {
        let html = "Hello&nbsp;World"
        let result = html.strippingHTML
        #expect(result == "Hello World")
    }

    @Test func strippingHTML_CollapsesMultipleBlankLines() {
        let html = "<p>A</p><p></p><p></p><p></p><p>B</p>"
        let result = html.strippingHTML
        // Should not have more than 2 consecutive newlines
        #expect(!result.contains("\n\n\n"))
    }

    @Test func strippingHTML_PlainTextUnchanged() {
        let text = "Just plain text with no HTML"
        #expect(text.strippingHTML == text)
    }

    @Test func strippingHTML_EmptyString() {
        #expect("".strippingHTML == "")
    }
}
