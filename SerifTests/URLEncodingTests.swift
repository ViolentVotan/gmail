import Testing
import Foundation
@testable import Serif

@Suite struct URLEncodingTests {

    @Test func buildLabelQueryEncodesSpecialChars() {
        let path = GmailPathBuilder.labelQueryParam("Label+Test")
        #expect(path == "&labelIds=Label%2BTest")
    }

    @Test func buildLabelQueryPassesThroughStandardLabels() {
        let path = GmailPathBuilder.labelQueryParam("INBOX")
        #expect(path == "&labelIds=INBOX")
    }

    @Test func buildSendAsPathEncodesPlus() {
        let path = GmailPathBuilder.sendAsPath("user+alias@example.com")
        #expect(path.contains("%2B"))
        #expect(!path.contains("+"))
        #expect(path.hasPrefix("/users/me/settings/sendAs/"))
    }
}
