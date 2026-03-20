import Foundation
import Testing
@testable import Vik

@Suite("ComposeViewModel — Reply Bar")
@MainActor
struct ComposeViewModelReplyTests {

    // MARK: - Helpers

    private func makeVM(threadID: String? = "thread-456") -> ComposeViewModel {
        ComposeViewModel(accountID: "test-account", fromAddress: "me@example.com", threadID: threadID)
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
        let vm = makeVM()
        let email = makeEmail(senderName: "Jane Doe")
        let mailStore = makeMailStore()

        vm.updateCollapsedPlaceholder(for: email, in: mailStore)

        #expect(vm.collapsedPlaceholderText == "Reply to Jane Doe\u{2026}")
    }

    @Test("collapsedPlaceholder shows Draft: when saved draft exists")
    func collapsedPlaceholderShowsDraft() {
        let vm = makeVM()
        let email = makeEmail()
        let mailStore = makeMailStore()
        mailStore.replyDrafts["thread-456"] = .init(gmailDraftID: "draft-1", preview: "Hello there")

        vm.updateCollapsedPlaceholder(for: email, in: mailStore)

        #expect(vm.collapsedPlaceholderText == "Draft: Hello there")
    }

    // MARK: - hasUserContent

    @Test("hasUserContent detects attachments")
    func hasUserContentWithAttachments() {
        let vm = makeVM()
        #expect(!vm.hasUserContent)

        vm.attachments = [URL(fileURLWithPath: "/tmp/test.pdf")]
        #expect(vm.hasUserContent)
    }

    @Test("hasUserContent detects cc recipients")
    func hasUserContentWithCc() {
        let vm = makeVM()
        #expect(!vm.hasUserContent)

        vm.cc = "someone@example.com"
        #expect(vm.hasUserContent)
    }

    // MARK: - Collapse

    @Test("collapse resets all business state")
    func collapseResetsState() {
        let vm = makeVM()
        let email = makeEmail()
        let mailStore = makeMailStore()

        // Set up some state
        vm.to = "someone@example.com"
        vm.cc = "cc@example.com"
        vm.bcc = "bcc@example.com"
        vm.body = "<p>Hello</p>"
        vm.attachments = [URL(fileURLWithPath: "/tmp/file.pdf")]
        vm.showCc = true
        vm.showBcc = true
        vm.sendError = "Some error"
        vm.subjectOverride = "Custom subject"

        vm.collapse(email: email, mailStore: mailStore)

        #expect(vm.to.isEmpty)
        #expect(vm.cc.isEmpty)
        #expect(vm.bcc.isEmpty)
        #expect(vm.body.isEmpty)
        #expect(vm.attachments.isEmpty)
        #expect(!vm.showCc)
        #expect(!vm.showBcc)
        #expect(vm.sendError == nil)
        #expect(vm.subjectOverride == nil)
        #expect(vm.collapsedPlaceholderText == "Write a reply...")
    }

    // MARK: - Discard Alert

    @Test("shouldShowDiscardAlert when draft exists in mailStore")
    func discardAlertWithSavedDraft() {
        let vm = makeVM()
        let email = makeEmail()
        let mailStore = makeMailStore()

        #expect(!vm.shouldShowDiscardAlert(email: email, mailStore: mailStore))

        mailStore.replyDrafts["thread-456"] = .init(gmailDraftID: "draft-1", preview: "test")
        #expect(vm.shouldShowDiscardAlert(email: email, mailStore: mailStore))
    }

    @Test("shouldShowDiscardAlert when gmailDraftID is set")
    func discardAlertWithGmailDraftID() {
        let vm = makeVM()
        let email = makeEmail()
        let mailStore = makeMailStore()

        vm.gmailDraftID = "remote-draft-id"
        #expect(vm.shouldShowDiscardAlert(email: email, mailStore: mailStore))
    }

    // MARK: - replyBodyIsEmpty

    @Test("replyBodyIsEmpty reflects cached stripped text")
    func replyBodyIsEmptyBaseline() {
        let vm = makeVM()
        #expect(vm.replyBodyIsEmpty)
    }

    // MARK: - resetForEmail

    @Test("resetForEmail resets isInitialLoad and isLoadingDraft")
    func resetForEmailResetsGuards() async {
        let vm = makeVM()
        vm.isInitialLoad = false
        vm.isLoadingDraft = true
        let email = makeEmail()
        vm.resetForEmail(email)
        #expect(vm.isInitialLoad == true)
        #expect(vm.isLoadingDraft == false)
    }
}
