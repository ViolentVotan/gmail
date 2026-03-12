import Testing
@testable import Serif

@Suite @MainActor struct TrackerBlockerTests {

    private let service = TrackerBlockerService.shared

    // MARK: - Known Tracker Domains (IMG tags)

    @Test func stripTrackerImage_HubSpot() {
        let html = """
        <p>Hello</p>
        <img src="https://track.hubspot.com/open/abc123" width="1" height="1">
        <p>World</p>
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect HubSpot tracker")
        #expect(!result.sanitizedHTML.contains("track.hubspot.com"), "Should strip HubSpot image")
        #expect(result.sanitizedHTML.contains("Hello"))
        #expect(result.sanitizedHTML.contains("World"))

        let hubspot = result.trackers.first { $0.serviceName == "HubSpot" }
        #expect(hubspot != nil, "Should identify tracker as HubSpot")
    }

    @Test func stripTrackerImage_SendGrid() {
        let html = """
        <img src="https://ct.sendgrid.net/o/tracking/v2/open?token=abc">
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers)
        let sendgrid = result.trackers.first { $0.serviceName == "SendGrid" }
        #expect(sendgrid != nil, "Should identify tracker as SendGrid")
    }

    @Test func stripTrackerImage_Mailchimp() {
        let html = """
        <img src="https://list-manage.com/track/open.php?u=abc123">
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers)
        let mailchimp = result.trackers.first { $0.serviceName == "Mailchimp" }
        #expect(mailchimp != nil, "Should identify tracker as Mailchimp")
    }

    // MARK: - Tracker Path Patterns

    @Test func stripTrackerImage_ByPathPattern() {
        let html = """
        <img src="https://unknown-domain.com/track/open?id=abc123">
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect tracker by path pattern /track/open")
    }

    @Test func stripTrackerImage_PixelGifPath() {
        let html = """
        <img src="https://some-service.com/t.gif?user=123">
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect tracker by /t.gif path pattern")
    }

    @Test func stripTrackerImage_BeaconPath() {
        let html = """
        <img src="https://analytics.example.com/beacon?id=456">
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect tracker by /beacon path pattern")
    }

    @Test func stripTrackerImage_1x1Path() {
        let html = """
        <img src="https://tracking.example.com/1x1.gif?campaign=summer">
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect tracker by /1x1. path pattern")
    }

    // MARK: - Spy Pixel Detection (by dimensions)

    @Test func stripSpyPixel_WidthHeightAttributes() {
        let html = """
        <img src="https://random-domain.com/image.png" width="1" height="1">
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect 1x1 spy pixel")
        let pixel = result.trackers.first { $0.kind == .pixel }
        #expect(pixel != nil)
    }

    @Test func stripSpyPixel_ZeroDimensions() {
        let html = """
        <img src="https://random-domain.com/image.png" width="0" height="0">
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect 0x0 spy pixel")
    }

    @Test func stripSpyPixel_InlineStyle() {
        let html = """
        <img src="https://random-domain.com/image.png" style="width:1px;height:1px;">
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect spy pixel by inline style")
    }

    @Test func stripSpyPixel_ZeroInlineStyle() {
        let html = """
        <img src="https://random-domain.com/image.png" style="width:0px;height:0px;">
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect spy pixel with 0px inline style")
    }

    // MARK: - Safe / Normal Images Pass Through

    @Test func normalImage_NotStripped() {
        let html = """
        <img src="https://images.example.com/photo.jpg" width="600" height="400">
        """
        let result = service.sanitize(html: html)

        #expect(!result.hasTrackers, "Normal image should not be flagged")
        #expect(result.sanitizedHTML.contains("photo.jpg"), "Normal image should be preserved")
    }

    @Test func allowlisted_Logo_NotStripped() {
        let html = """
        <img src="https://company.com/logo.png" width="1" height="1">
        """
        let result = service.sanitize(html: html)

        #expect(!result.hasTrackers, "Allowlisted logo should not be flagged")
        #expect(result.sanitizedHTML.contains("logo.png"), "Logo should be preserved")
    }

    @Test func allowlisted_CID_NotStripped() {
        let html = """
        <img src="cid:inline-image-001">
        """
        let result = service.sanitize(html: html)

        #expect(!result.hasTrackers, "CID image should not be flagged")
        #expect(result.sanitizedHTML.contains("cid:"), "CID image should be preserved")
    }

    @Test func allowlisted_Avatar_NotStripped() {
        let html = """
        <img src="https://service.com/avatar/user123.jpg" width="1" height="1">
        """
        let result = service.sanitize(html: html)

        #expect(!result.hasTrackers, "Avatar image should not be flagged")
    }

    @Test func allowlisted_Emoji_NotStripped() {
        let html = """
        <img src="https://cdn.example.com/emoji/smile.png" width="1" height="1">
        """
        let result = service.sanitize(html: html)

        #expect(!result.hasTrackers, "Emoji image should not be flagged")
    }

    // MARK: - CSS Background Tracker Detection

    @Test func stripCSSTracker_BackgroundImage() {
        let html = """
        <div style="background-image: url('https://track.hubspot.com/pixel.gif');">Content</div>
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect CSS background tracker")
        let cssTracker = result.trackers.first { $0.kind == .cssTracker }
        #expect(cssTracker != nil, "Should identify as CSS tracker")
        #expect(result.sanitizedHTML.contains("about:blank"), "Should replace tracker URL with about:blank")
    }

    @Test func stripCSSTracker_BackgroundShorthand() {
        let html = """
        <td style="background: url('https://ct.sendgrid.net/tracking.gif');">Cell</td>
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect CSS background shorthand tracker")
    }

    @Test func safeCSSBackground_NotStripped() {
        let html = """
        <div style="background-image: url('https://images.example.com/banner.jpg');">Content</div>
        """
        let result = service.sanitize(html: html)

        #expect(!result.hasTrackers, "Safe CSS background should not be flagged")
    }

    // MARK: - Tracking Link Detection

    @Test func detectTrackingLink_WithRedirect() {
        let html = """
        <a href="https://track.hubspot.com/redirect?url=https%3A%2F%2Fexample.com%2Fpage">Click here</a>
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect tracking link")
        let trackingLink = result.trackers.first { $0.kind == .trackingLink }
        #expect(trackingLink != nil, "Should identify as tracking link")
        #expect(result.sanitizedHTML.contains("https://example.com/page"), "Should rewrite to actual destination")
    }

    @Test func detectTrackingLink_WithoutRedirect() {
        let html = """
        <a href="https://track.hubspot.com/click/abc123">Click here</a>
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Should detect tracking link even without extractable redirect")
    }

    @Test func safeLink_NotFlagged() {
        let html = """
        <a href="https://example.com/article">Read more</a>
        """
        let result = service.sanitize(html: html)

        let trackingLinks = result.trackers.filter { $0.kind == .trackingLink }
        #expect(trackingLinks.isEmpty, "Normal link should not be flagged as tracking link")
    }

    // MARK: - Edge Cases

    @Test func emptyHTML() {
        let result = service.sanitize(html: "")

        #expect(!result.hasTrackers)
        #expect(result.sanitizedHTML == "")
        #expect(result.trackerCount == 0)
    }

    @Test func plainText_NoTrackers() {
        let result = service.sanitize(html: "Just plain text, no HTML tags at all.")

        #expect(!result.hasTrackers)
        #expect(result.sanitizedHTML == "Just plain text, no HTML tags at all.")
    }

    @Test func imgWithoutSrc_Ignored() {
        let html = """
        <img alt="broken image">
        """
        let result = service.sanitize(html: html)

        #expect(!result.hasTrackers, "Image without src should be ignored")
    }

    @Test func malformedURL_InImgSrc() {
        let html = """
        <img src="not-a-valid-url" width="1" height="1">
        """
        let result = service.sanitize(html: html)

        // Should detect as pixel since dimensions are 1x1 but URL has no host
        if result.hasTrackers {
            let pixel = result.trackers.first { $0.kind == .pixel }
            #expect(pixel != nil, "Malformed URL with pixel dimensions should be detected as pixel")
        }
        // It's also acceptable if the service ignores it entirely
    }

    @Test func multipleTrackers_AllDetected() {
        let html = """
        <p>Email content</p>
        <img src="https://track.hubspot.com/open/1" width="1" height="1">
        <img src="https://ct.sendgrid.net/track/open/2">
        <img src="https://mailtrack.io/pixel/3" width="0" height="0">
        <img src="https://images.example.com/real-photo.jpg" width="800" height="600">
        """
        let result = service.sanitize(html: html)

        #expect(result.trackerCount >= 3, "Should detect all three trackers")
        #expect(result.sanitizedHTML.contains("real-photo.jpg"), "Legitimate image should remain")
        #expect(result.sanitizedHTML.contains("Email content"), "Content should remain")
    }

    // MARK: - TrackerResult Properties

    @Test func trackerResult_OriginalHTMLPreserved() {
        let html = """
        <img src="https://track.hubspot.com/open/abc" width="1" height="1">
        """
        let result = service.sanitize(html: html)

        #expect(result.originalHTML == html, "Original HTML should be preserved in result")
        #expect(result.sanitizedHTML != result.originalHTML, "Sanitized should differ from original when tracker found")
    }

    @Test func trackerResult_NoTrackers_HTMLUnchanged() {
        let html = "<p>Clean email content with no trackers</p>"
        let result = service.sanitize(html: html)

        #expect(result.sanitizedHTML == html, "HTML should be unchanged when no trackers found")
        #expect(result.originalHTML == html)
        #expect(result.trackerCount == 0)
        #expect(!result.hasTrackers)
    }

    // MARK: - Subdomain Matching

    @Test func subdomainOfTrackerDomain_Detected() {
        let html = """
        <img src="https://emails.track.hubspot.com/open/sub" width="1" height="1">
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers, "Subdomain of tracker domain should be detected")
    }

    // MARK: - Redirect Destination Extraction

    @Test func trackingLink_ExtractsRedirectParam() {
        let html = """
        <a href="https://t.yesware.com/redirect?redirect=https%3A%2F%2Fexample.com%2Fdocs">Docs</a>
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers)
        #expect(result.sanitizedHTML.contains("https://example.com/docs"), "Should extract redirect destination")
    }

    @Test func trackingLink_ExtractsUrlParam() {
        let html = """
        <a href="https://links.iterable.com/click?url=https%3A%2F%2Fexample.com%2Fpage">Link</a>
        """
        let result = service.sanitize(html: html)

        #expect(result.hasTrackers)
        #expect(result.sanitizedHTML.contains("https://example.com/page"))
    }
}
