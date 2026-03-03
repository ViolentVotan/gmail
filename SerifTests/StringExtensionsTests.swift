import XCTest
@testable import Serif

final class StringExtensionsTests: XCTestCase {

    // MARK: - strippingHTML

    func testStrippingHTML_RemovesTags() {
        let html = "<p>Hello <b>World</b></p>"
        let result = html.strippingHTML
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("World"))
        XCTAssertFalse(result.contains("<b>"))
        XCTAssertFalse(result.contains("</b>"))
        XCTAssertFalse(result.contains("<p>"))
    }

    func testStrippingHTML_ReplacesBreaksWithNewlines() {
        let html = "Line1<br>Line2<br/>Line3"
        let result = html.strippingHTML
        XCTAssertTrue(result.contains("Line1"))
        XCTAssertTrue(result.contains("Line2"))
        XCTAssertTrue(result.contains("Line3"))
    }

    func testStrippingHTML_DecodesEntities() {
        let html = "&lt;hello&gt; &amp; &quot;world&quot; &#39;test&#39;"
        let result = html.strippingHTML
        XCTAssertTrue(result.contains("<hello>"))
        XCTAssertTrue(result.contains("& \"world\""))
        XCTAssertTrue(result.contains("'test'"))
    }

    func testStrippingHTML_RemovesStyleBlocks() {
        let html = "<style>body { color: red; }</style><p>Content</p>"
        let result = html.strippingHTML
        XCTAssertFalse(result.contains("color"))
        XCTAssertTrue(result.contains("Content"))
    }

    func testStrippingHTML_RemovesScriptBlocks() {
        let html = "<script>alert('xss')</script><p>Safe</p>"
        let result = html.strippingHTML
        XCTAssertFalse(result.contains("alert"))
        XCTAssertTrue(result.contains("Safe"))
    }

    func testStrippingHTML_ReplacesNbsp() {
        let html = "Hello&nbsp;World"
        let result = html.strippingHTML
        XCTAssertEqual(result, "Hello World")
    }

    func testStrippingHTML_CollapsesMultipleBlankLines() {
        let html = "<p>A</p><p></p><p></p><p></p><p>B</p>"
        let result = html.strippingHTML
        // Should not have more than 2 consecutive newlines
        XCTAssertFalse(result.contains("\n\n\n"))
    }

    func testStrippingHTML_PlainTextUnchanged() {
        let text = "Just plain text with no HTML"
        XCTAssertEqual(text.strippingHTML, text)
    }

    func testStrippingHTML_EmptyString() {
        XCTAssertEqual("".strippingHTML, "")
    }
}
