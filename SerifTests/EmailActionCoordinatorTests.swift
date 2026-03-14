import Testing
import Foundation
@testable import Serif

@Suite @MainActor struct EmailActionCoordinatorTests {

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
    @Test func archiveEmail_doesNotAutoSelectNext() {
        let (coordinator, vm) = makeCoordinator()
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .inbox
        )

        coordinator.archiveEmail(email, selectNext: { receivedEmail = $0 })

        #expect(receivedEmail == nil, "archiveEmail should pass nil to selectNext, not auto-select another email")
    }

    @Test func deleteEmail_doesNotAutoSelectNext() {
        let (coordinator, vm) = makeCoordinator()
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .inbox
        )

        coordinator.deleteEmail(email, selectNext: { receivedEmail = $0 })

        #expect(receivedEmail == nil, "deleteEmail should pass nil to selectNext, not auto-select another email")
    }

    @Test func moveToInboxEmail_doesNotAutoSelectNext() {
        let (coordinator, vm) = makeCoordinator()
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .trash
        )

        coordinator.moveToInboxEmail(email, selectedFolder: .trash, selectNext: { receivedEmail = $0 })

        #expect(receivedEmail == nil, "moveToInboxEmail should pass nil to selectNext, not auto-select another email")
    }

    @Test func deletePermanentlyEmail_doesNotAutoSelectNext() {
        let (coordinator, vm) = makeCoordinator()
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .trash
        )

        coordinator.deletePermanentlyEmail(email, selectNext: { receivedEmail = $0 })

        #expect(receivedEmail == nil, "deletePermanentlyEmail should pass nil to selectNext, not auto-select another email")
    }

    @Test func markNotSpamEmail_doesNotAutoSelectNext() {
        let (coordinator, vm) = makeCoordinator()
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .spam
        )

        coordinator.markNotSpamEmail(email, selectNext: { receivedEmail = $0 })

        #expect(receivedEmail == nil, "markNotSpamEmail should pass nil to selectNext, not auto-select another email")
    }
}
