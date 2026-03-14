import Testing
@testable import Serif

@Suite struct GmailSendAsBestAliasTests {

    private let aliases: [GmailSendAs] = [
        GmailSendAs(sendAsEmail: "primary@example.com", displayName: "Primary", signature: nil, isDefault: true, isPrimary: true),
        GmailSendAs(sendAsEmail: "alias@example.com", displayName: "Alias", signature: nil, isDefault: false, isPrimary: false),
        GmailSendAs(sendAsEmail: "work@company.com", displayName: "Work", signature: nil, isDefault: false, isPrimary: false),
    ]

    @Test func noAliases_returnsNil() {
        let empty: [GmailSendAs] = []
        #expect(empty.bestAlias(toRecipients: ["anyone@test.com"], ccRecipients: []) == nil)
    }

    @Test func matchInTo_returnsAlias() {
        let result = aliases.bestAlias(toRecipients: ["alias@example.com"], ccRecipients: [])
        #expect(result == "alias@example.com")
    }

    @Test func matchInCc_returnsAlias() {
        let result = aliases.bestAlias(toRecipients: ["stranger@test.com"], ccRecipients: ["work@company.com"])
        #expect(result == "work@company.com")
    }

    @Test func toTakesPriorityOverCc() {
        let result = aliases.bestAlias(
            toRecipients: ["alias@example.com"],
            ccRecipients: ["work@company.com"]
        )
        #expect(result == "alias@example.com")
    }

    @Test func caseInsensitiveMatching() {
        let result = aliases.bestAlias(toRecipients: ["ALIAS@Example.COM"], ccRecipients: [])
        #expect(result == "alias@example.com")
    }

    @Test func noMatch_returnsNil() {
        let result = aliases.bestAlias(toRecipients: ["unknown@test.com"], ccRecipients: ["other@test.com"])
        #expect(result == nil)
    }

    @Test func emptyRecipients_returnsNil() {
        let result = aliases.bestAlias(toRecipients: [], ccRecipients: [])
        #expect(result == nil)
    }
}
