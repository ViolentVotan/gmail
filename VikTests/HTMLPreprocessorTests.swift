import Testing
@testable import Vik

@Suite struct HTMLPreprocessorTests {

    // MARK: - HTML Comments (existing behavior)

    @Test func stripHTMLComment_Basic() {
        let html = "<p>Hello</p><!-- this is a comment --><p>World</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("this is a comment"))
        #expect(result.contains("Hello"))
        #expect(result.contains("World"))
    }

    @Test func stripHTMLComment_MultiLine() {
        let html = """
        <p>Before</p>
        <!--
            Multi-line
            comment block
        -->
        <p>After</p>
        """
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("Multi-line"))
        #expect(!result.contains("comment block"))
        #expect(result.contains("Before"))
        #expect(result.contains("After"))
    }

    @Test func stripHTMLComment_MultipleComments() {
        let html = "<!-- a -->Hello<!-- b -->World<!-- c -->"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("<!--"))
        #expect(!result.contains("-->"))
        #expect(result.contains("Hello"))
        #expect(result.contains("World"))
    }

    @Test func stripHTMLComment_LinkedInBloat() {
        // LinkedIn emails contain 30-40KB of HTML comments
        let comment = String(repeating: "x", count: 10_000)
        let html = "<p>Content</p><!-- \(comment) --><p>End</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains(comment))
        #expect(result.contains("Content"))
        #expect(result.contains("End"))
        #expect(result.count < html.count / 2)
    }

    @Test func stripHTMLComment_UnclosedCommentKept() {
        // Unclosed comment — preserve remaining HTML to avoid breakage
        let html = "<p>Before</p><!-- unclosed comment"
        let result = HTMLPreprocessor.strip(html)
        #expect(result.contains("Before"))
    }

    // MARK: - Blocked Tags (existing behavior)

    @Test func stripBlockedTag_Script() {
        let html = "<p>Safe</p><script>alert('xss')</script><p>Also safe</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("alert"))
        #expect(!result.contains("<script"))
        #expect(result.contains("Safe"))
        #expect(result.contains("Also safe"))
    }

    @Test func stripBlockedTag_ScriptCaseInsensitive() {
        let html = "<p>Safe</p><SCRIPT>evil()</SCRIPT><p>Also safe</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("evil()"))
        #expect(result.contains("Safe"))
    }

    @Test func stripBlockedTag_Iframe() {
        let html = "<p>Content</p><iframe src=\"https://evil.com\"></iframe>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("<iframe"))
        #expect(!result.contains("evil.com"))
        #expect(result.contains("Content"))
    }

    @Test func stripBlockedTag_Form() {
        let html = "<form action=\"/submit\"><input type=\"text\"><button>Submit</button></form><p>After</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("<form"))
        #expect(!result.contains("Submit"))
        #expect(result.contains("After"))
    }

    @Test func stripBlockedTag_Object() {
        let html = "<object data=\"flash.swf\"><param name=\"quality\" value=\"high\"></object>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("<object"))
        #expect(!result.contains("flash.swf"))
    }

    @Test func stripBlockedTag_Embed() {
        let html = "<embed src=\"plugin.swf\"><p>Text</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("<embed"))
        #expect(result.contains("Text"))
    }

    @Test func stripBlockedTag_Applet() {
        let html = "<applet code=\"App.class\"></applet><p>Text</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("<applet"))
        #expect(result.contains("Text"))
    }

    // MARK: - Inter-tag Whitespace Collapse (existing behavior)

    @Test func collapseInterTagWhitespace_BasicSpaces() {
        let html = "<p>Hello</p>   <p>World</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("   "))
    }

    @Test func collapseInterTagWhitespace_NewlinesCollapsed() {
        let html = "<p>A</p>\n\n\n<p>B</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("\n\n"))
    }

    @Test func collapseInterTagWhitespace_TextContentPreserved() {
        // Whitespace inside text content must not be collapsed
        let html = "<p>Hello   World</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(result.contains("Hello   World"))
    }

    // MARK: - Head Element Stripping (new behavior)

    @Test func stripHead_FullHeadElement() {
        let html = "<html><head><title>Email Title</title><meta charset=\"utf-8\"></head><body><p>Content</p></body></html>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("<head>"))
        #expect(!result.contains("</head>"))
        #expect(!result.contains("Email Title"))
        #expect(result.contains("Content"))
    }

    @Test func stripHead_WithStyleInHead() {
        let html = "<head><style>body { color: red; }</style></head><body><p>Text</p></body>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("<head>"))
        // Style blocks are extracted and preserved — email CSS is needed for layout
        #expect(result.contains("body { color: red; }"))
        #expect(result.contains("Text"))
    }

    @Test func stripHead_CaseInsensitive() {
        let html = "<HEAD><TITLE>Title</TITLE></HEAD><BODY><p>Text</p></BODY>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("Title"))
        #expect(result.contains("Text"))
    }

    // MARK: - Style Block Preservation

    @Test func stripStyle_BasicStyleBlock_Preserved() {
        // Style blocks are preserved — email CSS is needed for proper layout
        let html = "<style>body { font-family: Arial; color: #333; }</style><p>Content</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(result.contains("<style>"))
        #expect(result.contains("font-family"))
        #expect(result.contains("Content"))
    }

    @Test func stripStyle_CaseInsensitive_Preserved() {
        let html = "<STYLE>div { display: block; }</STYLE><p>Text</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(result.contains("display: block"))
        #expect(result.contains("Text"))
    }

    @Test func stripStyle_MultipleStyleBlocks_Preserved() {
        let html = "<style>.a { color: red; }</style><p>Hello</p><style>.b { color: blue; }</style>"
        let result = HTMLPreprocessor.strip(html)
        #expect(result.contains("color: red"))
        #expect(result.contains("color: blue"))
        #expect(result.contains("Hello"))
    }

    @Test func stripStyle_WithTypeAttribute_Preserved() {
        let html = "<style type=\"text/css\">.foo { margin: 0; }</style><p>Text</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(result.contains("margin: 0"))
        #expect(result.contains("Text"))
    }

    // MARK: - MSO Conditional Comments (new behavior)

    @Test func stripMSOConditional_IfMso() {
        let html = "<p>Before</p><!--[if mso]><table><tr><td>MSO only</td></tr></table><![endif]--><p>After</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("MSO only"))
        #expect(!result.contains("[if mso]"))
        #expect(!result.contains("[endif]"))
        #expect(result.contains("Before"))
        #expect(result.contains("After"))
    }

    @Test func stripMSOConditional_IfMsoVersion() {
        let html = "<!--[if mso 15]><v:shape>VML content</v:shape><![endif]--><p>Text</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("VML content"))
        #expect(result.contains("Text"))
    }

    @Test func stripMSOConditional_IfNotMso() {
        // <!--[if !mso]> content should be preserved (it's non-MSO content)
        let html = "<!--[if !mso]><p>Non-MSO content</p><![endif]-->"
        let result = HTMLPreprocessor.strip(html)
        #expect(result.contains("Non-MSO content"))
    }

    @Test func stripMSOConditional_NestedInEmail() {
        let html = """
        <p>Real content</p>
        <!--[if mso]>
        <table width="600"><tr><td>
        <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml">MSO button</v:roundrect>
        </td></tr></table>
        <![endif]-->
        <p>More content</p>
        """
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("MSO button"))
        #expect(!result.contains("v:roundrect"))
        #expect(result.contains("Real content"))
        #expect(result.contains("More content"))
    }

    // MARK: - Hidden Element Stripping (new behavior)

    @Test func stripHiddenElement_DisplayNone() {
        let html = "<div style=\"display:none\">Hidden content</div><p>Visible</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("Hidden content"))
        #expect(result.contains("Visible"))
    }

    @Test func stripHiddenElement_DisplayNoneWithSpaces() {
        let html = "<div style=\"display: none;\">Hidden</div><p>Visible</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("Hidden"))
        #expect(result.contains("Visible"))
    }

    @Test func stripHiddenElement_VisibilityHidden() {
        let html = "<span style=\"visibility:hidden\">Invisible text</span><p>Visible</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("Invisible text"))
        #expect(result.contains("Visible"))
    }

    @Test func stripHiddenElement_MsoHideAll() {
        let html = "<div style=\"mso-hide:all\">MSO hidden</div><p>Text</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("MSO hidden"))
        #expect(result.contains("Text"))
    }

    @Test func stripHiddenElement_MaxHeightZero() {
        let html = "<div style=\"max-height:0\">Collapsed</div><p>Text</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("Collapsed"))
        #expect(result.contains("Text"))
    }

    @Test func stripHiddenElement_MaxHeightZeroPx() {
        let html = "<div style=\"max-height:0px;overflow:hidden\">Hidden</div><p>Text</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("Hidden"))
        #expect(result.contains("Text"))
    }

    @Test func stripHiddenElement_MultipleStyleProperties() {
        let html = "<div style=\"color:red;display:none;font-size:12px\">Hidden</div><p>Text</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("Hidden"))
        #expect(result.contains("Text"))
    }

    // MARK: - data-* Attribute Stripping (new behavior)

    @Test func stripDataAttributes_Basic() {
        let html = "<p data-tracking-id=\"abc123\">Content</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("data-tracking-id"))
        #expect(!result.contains("abc123"))
        #expect(result.contains("Content"))
    }

    @Test func stripDataAttributes_MultipleDataAttrs() {
        let html = "<a href=\"https://example.com\" data-link-id=\"1\" data-campaign=\"summer\">Link</a>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("data-link-id"))
        #expect(!result.contains("data-campaign"))
        #expect(result.contains("href=\"https://example.com\""))
        #expect(result.contains("Link"))
    }

    @Test func stripDataAttributes_PreservesClassAndId() {
        // class and id must NOT be stripped — needed by stripQuotedHTML for gmail_quote/divRplyFwdMsg detection
        let html = "<div class=\"gmail_quote\" id=\"divRplyFwdMsg\" data-type=\"quoted\">Quoted content</div>"
        let result = HTMLPreprocessor.strip(html)
        #expect(result.contains("class=\"gmail_quote\""))
        #expect(result.contains("id=\"divRplyFwdMsg\""))
        #expect(!result.contains("data-type"))
    }

    @Test func stripDataAttributes_PreservesHref() {
        let html = "<a href=\"https://example.com\" data-click-id=\"xyz\">Click</a>"
        let result = HTMLPreprocessor.strip(html)
        #expect(result.contains("href=\"https://example.com\""))
        #expect(!result.contains("data-click-id"))
    }

    // MARK: - MSO CSS Property Stripping (new behavior)

    @Test func stripMSOCSSProperties_BasicMsoProperty() {
        let html = "<p style=\"mso-line-height-rule:exactly;color:red\">Text</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("mso-line-height-rule"))
        #expect(result.contains("color:red"))
        #expect(result.contains("Text"))
    }

    @Test func stripMSOCSSProperties_MultipleMsoProperties() {
        let html = "<td style=\"mso-padding-top-alt:0;mso-padding-bottom-alt:0;mso-padding-left-alt:0\">Cell</td>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("mso-padding"))
        #expect(result.contains("Cell"))
    }

    @Test func stripMSOCSSProperties_RemovesStyleAttrIfEmpty() {
        // Style attribute should be removed entirely if all properties are mso-*
        let html = "<p style=\"mso-line-height-rule:exactly;mso-fareast-font-family:Arial\">Text</p>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("mso-"))
        #expect(!result.contains("style=\"\""))
        #expect(!result.contains("style=\" \""))
        #expect(result.contains("Text"))
    }

    @Test func stripMSOCSSProperties_KeepsNonMsoProperties() {
        let html = "<span style=\"font-size:14px;mso-font-width:100%;color:blue\">Text</span>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("mso-font-width"))
        #expect(result.contains("font-size:14px"))
        #expect(result.contains("color:blue"))
    }

    // MARK: - Tracking URL Query Parameter Stripping (new behavior)

    @Test func stripTrackingParams_TrackingId() {
        let html = "<a href=\"https://example.com/page?trackingId=abc123&ref=email\">Link</a>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("trackingId=abc123"))
        #expect(result.contains("ref=email"))
        #expect(result.contains("example.com/page"))
    }

    @Test func stripTrackingParams_TrkEmail() {
        let html = "<a href=\"https://example.com/blog?trkEmail=def456&page=1\">Blog</a>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("trkEmail=def456"))
        #expect(result.contains("page=1"))
    }

    @Test func stripTrackingParams_OtpToken() {
        let html = "<a href=\"https://example.com/verify?otpToken=xyz789&next=/home\">Verify</a>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("otpToken=xyz789"))
        #expect(result.contains("next=/home"))
    }

    @Test func stripTrackingParams_UtmParameters() {
        let html = "<a href=\"https://example.com/?utm_source=email&utm_medium=newsletter&utm_campaign=spring\">Visit</a>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("utm_source"))
        #expect(!result.contains("utm_medium"))
        #expect(!result.contains("utm_campaign"))
        #expect(result.contains("example.com"))
    }

    @Test func stripTrackingParams_LinkedInParams() {
        let html = "<a href=\"https://linkedin.com/in/user?midToken=abc&eid=xyz&lipi=foo&loid=bar&midSig=baz\">Profile</a>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("midToken="))
        #expect(!result.contains("eid="))
        #expect(!result.contains("lipi="))
        #expect(!result.contains("loid="))
        #expect(!result.contains("midSig="))
        #expect(result.contains("linkedin.com/in/user"))
    }

    @Test func stripTrackingParams_PreservesNonTrackingParams() {
        let html = "<a href=\"https://example.com/search?q=hello&page=2&sort=date\">Search</a>"
        let result = HTMLPreprocessor.strip(html)
        #expect(result.contains("q=hello"))
        #expect(result.contains("page=2"))
        #expect(result.contains("sort=date"))
    }

    @Test func stripTrackingParams_CleanURLUnchanged() {
        let html = "<a href=\"https://example.com/article\">Article</a>"
        let result = HTMLPreprocessor.strip(html)
        #expect(result.contains("https://example.com/article"))
    }

    @Test func stripTrackingParams_AllTrackingNoRemainingParams() {
        // URL with only tracking params — query string should be removed entirely
        let html = "<a href=\"https://example.com/page?utm_source=email&utm_medium=cta\">CTA</a>"
        let result = HTMLPreprocessor.strip(html)
        #expect(!result.contains("utm_source"))
        #expect(!result.contains("utm_medium"))
        // Clean URL should remain (with or without trailing ?)
        #expect(result.contains("example.com/page"))
        #expect(!result.contains("?utm"))
    }

    // MARK: - Full Pipeline Integration (new + existing behavior)

    @Test func integrationTest_LinkedInStyleBloat() {
        // Simulates a LinkedIn marketing email with all known bloat patterns combined.
        // Verifies >50% size reduction after stripping.
        let msoConditional = "<!--[if mso]><table width=\"600\"><tr><td><v:shape>MSO button</v:shape></td></tr></table><![endif]-->"
        let htmlComments = String(repeating: "<!-- LinkedIn bloat comment padding data ", count: 50) + "-->"
        let headBlock = "<head><title>LinkedIn Update</title><style>body{mso-line-height-rule:exactly;font-family:Arial;}</style></head>"
        let styleBlock = "<style type=\"text/css\">.ExternalClass{width:100%;} .ExternalClass *{line-height:100%;}</style>"
        let hiddenDiv = "<div style=\"display:none;max-height:0;overflow:hidden\">Preview text hidden from email body</div>"
        let dataAttrs = "<table data-tracking-id=\"li-email-001\" data-campaign=\"may-newsletter\" width=\"600\">"
        let msoStyle = "<td style=\"mso-padding-alt:0px 9px 0px 9px;color:red\">Cell content</td>"
        let trackingLink = "<a href=\"https://linkedin.com/comm/click?midToken=abc&eid=xyz&utm_source=email&utm_campaign=spring&redirectUrl=https%3A%2F%2Flinkedin.com%2Fjobs\">View Jobs</a>"
        let realContent = "<p>You have 5 new connection requests.</p>"

        let html = """
        <html>
        \(headBlock)
        <body>
        \(htmlComments)
        \(msoConditional)
        \(styleBlock)
        \(hiddenDiv)
        \(dataAttrs)
        <tr><td>
        \(msoStyle)
        \(trackingLink)
        \(realContent)
        </td></tr></table>
        </body></html>
        """

        let result = HTMLPreprocessor.strip(html)

        // Verify real content preserved
        #expect(result.contains("You have 5 new connection requests."))
        #expect(result.contains("View Jobs"))

        // Verify bloat stripped (style blocks are preserved for email layout)
        #expect(!result.contains("LinkedIn bloat comment padding"))
        #expect(!result.contains("MSO button"))
        #expect(result.contains("ExternalClass"), "Style blocks are preserved for email layout")
        #expect(!result.contains("Preview text hidden"))
        #expect(!result.contains("data-tracking-id"))
        #expect(!result.contains("data-campaign"))
        #expect(!result.contains("mso-padding-alt"))
        #expect(!result.contains("midToken="))
        #expect(!result.contains("utm_source="))

        // Verify >50% size reduction
        let reduction = Double(html.count - result.count) / Double(html.count)
        #expect(reduction > 0.50, "Expected >50% reduction, got \(Int(reduction * 100))%")
    }
}
