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
    @Test func archiveEmail_doesNotAutoSelectNext() async {
        let (coordinator, _) = makeCoordinator()
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .inbox
        )

        await coordinator.archiveEmail(email, selectNext: { receivedEmail = $0 })

        #expect(receivedEmail == nil, "archiveEmail should pass nil to selectNext, not auto-select another email")
    }

    @Test func deleteEmail_doesNotAutoSelectNext() async {
        let (coordinator, _) = makeCoordinator()
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .inbox
        )

        await coordinator.deleteEmail(email, selectNext: { receivedEmail = $0 })

        #expect(receivedEmail == nil, "deleteEmail should pass nil to selectNext, not auto-select another email")
    }

    // Note: moveToInboxEmail, deletePermanentlyEmail, and markNotSpamEmail
    // have an early return when NetworkMonitor.shared.isConnected is false.
    // These tests depend on isConnected being true (the default when NWPathMonitor
    // reports .satisfied). NetworkMonitor.isConnected is private(set) and the
    // coordinator uses the singleton directly, so DI is not currently possible.

    @Test func moveToInboxEmail_doesNotAutoSelectNext() async {
        let (coordinator, _) = makeCoordinator()
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .trash
        )

        await coordinator.moveToInboxEmail(email, selectedFolder: .trash, selectNext: { receivedEmail = $0 })

        #expect(receivedEmail == nil, "moveToInboxEmail should pass nil to selectNext, not auto-select another email")
    }

    @Test func deletePermanentlyEmail_doesNotAutoSelectNext() async {
        let (coordinator, _) = makeCoordinator()
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .trash
        )

        await coordinator.deletePermanentlyEmail(email, selectNext: { receivedEmail = $0 })

        #expect(receivedEmail == nil, "deletePermanentlyEmail should pass nil to selectNext, not auto-select another email")
    }

    @Test func markNotSpamEmail_doesNotAutoSelectNext() async {
        let (coordinator, _) = makeCoordinator()
        let email = makeTestEmail()

        var receivedEmail: Email? = Email(
            sender: Contact(name: "Sentinel", email: "sentinel@test.com"),
            subject: "Sentinel", body: "", preview: "", date: Date(), folder: .spam
        )

        await coordinator.markNotSpamEmail(email, selectNext: { receivedEmail = $0 })

        #expect(receivedEmail == nil, "markNotSpamEmail should pass nil to selectNext, not auto-select another email")
    }
}
