import Foundation
import Testing
@testable import Vik

@Suite("ReplyBarViewModel — Reply Bar")
@MainActor
struct ComposeViewModelReplyTests {

    // MARK: - Helpers

    private func makeVMs(threadID: String? = "thread-456") -> (ComposeViewModel, ReplyBarViewModel) {
        let compose = ComposeViewModel(accountID: "test-account", fromAddress: "me@example.com", threadID: threadID)
        let replyBar = ReplyBarViewModel(compose: compose)
        compose.replyBar = replyBar
        return (compose, replyBar)
    }

    private func makeEmail(
        gmailThreadID: String? = "thread-456",
        senderName: String = "Alice Sender"
    ) -> Email {
        .stub(
            sender: Contact(name: senderName, email: "alice@example.com"),
            gmailThreadID: gmailThreadID
        )
    }

    private func makeMailStore() -> MailStore {
        MailStore()
    }

    // MARK: - Collapsed Placeholder

    @Test("collapsedPlaceholder shows sender name when empty")
    func collapsedPlaceholderShowsSender() {
        let (_, replyBar) = makeVMs()
        let email = makeEmail(senderName: "Jane Doe")
        let mailStore = makeMailStore()

        replyBar.updateCollapsedPlaceholder(for: email, in: mailStore)

        #expect(replyBar.collapsedPlaceholderText == "Reply to Jane Doe\u{2026}")
    }

    @Test("collapsedPlaceholder shows Draft: when saved draft exists")
    func collapsedPlaceholderShowsDraft() {
        let (_, replyBar) = makeVMs()
        let email = makeEmail()
        let mailStore = makeMailStore()
        mailStore.replyDrafts["thread-456"] = .init(gmailDraftID: "draft-1", preview: "Hello there")

        replyBar.updateCollapsedPlaceholder(for: email, in: mailStore)

        #expect(replyBar.collapsedPlaceholderText == "Draft: Hello there")
    }

    // MARK: - hasUserContent

    @Test("hasUserContent detects attachments")
    func hasUserContentWithAttachments() {
        let (compose, replyBar) = makeVMs()
        #expect(!replyBar.hasUserContent)

        compose.attachments = [URL(fileURLWithPath: "/tmp/test.pdf")]
        #expect(replyBar.hasUserContent)
    }

    @Test("hasUserContent detects cc recipients")
    func hasUserContentWithCc() {
        let (compose, replyBar) = makeVMs()
        #expect(!replyBar.hasUserContent)

        compose.cc = "someone@example.com"
        #expect(replyBar.hasUserContent)
    }

    // MARK: - Collapse

    @Test("collapse resets all business state")
    func collapseResetsState() {
        let (compose, replyBar) = makeVMs()
        let email = makeEmail()
        let mailStore = makeMailStore()

        // Set up some state
        compose.to = "someone@example.com"
        compose.cc = "cc@example.com"
        compose.bcc = "bcc@example.com"
        compose.body = "<p>Hello</p>"
        compose.attachments = [URL(fileURLWithPath: "/tmp/file.pdf")]
        compose.showCc = true
        compose.showBcc = true
        replyBar.sendError = "Some error"
        replyBar.subjectOverride = "Custom subject"

        replyBar.collapse(email: email, mailStore: mailStore)

        #expect(compose.to.isEmpty)
        #expect(compose.cc.isEmpty)
        #expect(compose.bcc.isEmpty)
        #expect(compose.body.isEmpty)
        #expect(compose.attachments.isEmpty)
        #expect(!compose.showCc)
        #expect(!compose.showBcc)
        #expect(replyBar.sendError == nil)
        #expect(replyBar.subjectOverride == nil)
        #expect(replyBar.collapsedPlaceholderText == "Write a reply...")
    }

    // MARK: - Discard Alert

    @Test("shouldShowDiscardAlert when draft exists in mailStore")
    func discardAlertWithSavedDraft() {
        let (_, replyBar) = makeVMs()
        let email = makeEmail()
        let mailStore = makeMailStore()

        #expect(!replyBar.shouldShowDiscardAlert(email: email, mailStore: mailStore))

        mailStore.replyDrafts["thread-456"] = .init(gmailDraftID: "draft-1", preview: "test")
        #expect(replyBar.shouldShowDiscardAlert(email: email, mailStore: mailStore))
    }

    @Test("shouldShowDiscardAlert when gmailDraftID is set")
    func discardAlertWithGmailDraftID() {
        let (compose, replyBar) = makeVMs()
        let email = makeEmail()
        let mailStore = makeMailStore()

        compose.gmailDraftID = "remote-draft-id"
        #expect(replyBar.shouldShowDiscardAlert(email: email, mailStore: mailStore))
    }

    // MARK: - replyBodyIsEmpty

    @Test("replyBodyIsEmpty reflects cached stripped text")
    func replyBodyIsEmptyBaseline() {
        let (_, replyBar) = makeVMs()
        #expect(replyBar.replyBodyIsEmpty)
    }

    // MARK: - resetForEmail

    @Test("resetForEmail resets isInitialLoad and isLoadingDraft")
    func resetForEmailResetsGuards() async {
        let (_, replyBar) = makeVMs()
        replyBar.isInitialLoad = false
        replyBar.isLoadingDraft = true
        let email = makeEmail()
        replyBar.resetForEmail(email)
        #expect(replyBar.isInitialLoad == true)
        #expect(replyBar.isLoadingDraft == false)
    }
}
