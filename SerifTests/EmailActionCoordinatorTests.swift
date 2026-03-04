import XCTest
@testable import Serif

@MainActor
final class EmailActionCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestEmail(msgID: String = "msg_1") -> Email {
        Email(
            sender: Contact(name: "Test", email: "test@test.com"),
            subject: "Test",
            body: "Body",
            preview: "Preview",
            date: Date(),
            folder: .inbox,
            gmailMessageID: msgID
        )
    }

    private func makeGmailMessage(id: String = "msg_1") -> GmailMessage {
        GmailMessage(
            id: id,
            threadId: "thread_1",
            labelIds: ["INBOX"],
            snippet: "Preview",
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil,
            historyId: nil,
            raw: nil
        )
    }

    private func makeCoordinator() -> (EmailActionCoordinator, MailboxViewModel) {
        let vm = MailboxViewModel(accountID: "test")
        let store = MailStore()
        let coordinator = EmailActionCoordinator(mailboxViewModel: vm, mailStore: store)
        return (coordinator, vm)
    }

    // MARK: - No auto-selection after actions

    /// Regression test: after archiving an email, selectNext must receive nil.
    /// Bug: selectNext(vm.emails.first) would auto-open an unrelated email
    /// when the current folder became empty (e.g. Drafts after deleting all drafts).
    func testArchiveEmail_doesNotAutoSelectNext() {
        let (coordinator, vm) = makeCoordinator()
        let msg = makeGmailMessage()
        vm.messages = [msg]
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .inbox
        )

        coordinator.archiveEmail(email, selectNext: { receivedEmail = $0 })

        XCTAssertNil(receivedEmail, "archiveEmail should pass nil to selectNext, not auto-select another email")
    }

    func testDeleteEmail_doesNotAutoSelectNext() {
        let (coordinator, vm) = makeCoordinator()
        let msg = makeGmailMessage()
        vm.messages = [msg]
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .inbox
        )

        coordinator.deleteEmail(email, selectNext: { receivedEmail = $0 })

        XCTAssertNil(receivedEmail, "deleteEmail should pass nil to selectNext, not auto-select another email")
    }

    func testMoveToInboxEmail_doesNotAutoSelectNext() {
        let (coordinator, vm) = makeCoordinator()
        let msg = makeGmailMessage()
        vm.messages = [msg]
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .trash
        )

        coordinator.moveToInboxEmail(email, selectedFolder: .trash, selectNext: { receivedEmail = $0 })

        XCTAssertNil(receivedEmail, "moveToInboxEmail should pass nil to selectNext, not auto-select another email")
    }

    func testDeletePermanentlyEmail_doesNotAutoSelectNext() {
        let (coordinator, vm) = makeCoordinator()
        let msg = makeGmailMessage()
        vm.messages = [msg]
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .trash
        )

        coordinator.deletePermanentlyEmail(email, selectNext: { receivedEmail = $0 })

        XCTAssertNil(receivedEmail, "deletePermanentlyEmail should pass nil to selectNext, not auto-select another email")
    }

    func testMarkNotSpamEmail_doesNotAutoSelectNext() {
        let (coordinator, vm) = makeCoordinator()
        let msg = makeGmailMessage()
        vm.messages = [msg]
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .spam
        )

        coordinator.markNotSpamEmail(email, selectNext: { receivedEmail = $0 })

        XCTAssertNil(receivedEmail, "markNotSpamEmail should pass nil to selectNext, not auto-select another email")
    }
}
