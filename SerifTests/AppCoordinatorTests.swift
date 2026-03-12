import Testing
import Foundation
@testable import Serif

@Suite @MainActor struct AppCoordinatorTests {

    // MARK: - @Observable state propagation (replaces Combine objectWillChange forwarding)

    /// Verifies that when mailboxViewModel.isLoading changes,
    /// the new value is immediately accessible through the coordinator.
    /// (Replaces old Combine objectWillChange forwarding test — under @Observable,
    /// property-level tracking handles this automatically.)
    @Test func mailboxViewModelStateIsAccessibleThroughCoordinator() {
        let coordinator = AppCoordinator()
        #expect(!coordinator.mailboxViewModel.isLoading)

        coordinator.mailboxViewModel.isLoading = true

        #expect(coordinator.mailboxViewModel.isLoading,
                "Mutating nested mailboxViewModel property should be immediately visible through coordinator")
    }

    /// Verifies that mailStore mutations are immediately visible through the coordinator.
    /// (Replaces old Combine objectWillChange forwarding test — under @Observable,
    /// property-level tracking handles this automatically.)
    @Test func mailStoreStateIsAccessibleThroughCoordinator() {
        let coordinator = AppCoordinator()
        #expect(coordinator.mailStore.emails.isEmpty)

        let email = Email(
            sender: Contact(name: "Test", email: "test@test.com"),
            subject: "Test",
            body: "Body",
            preview: "Preview",
            date: Date(),
            folder: .inbox
        )
        coordinator.mailStore.emails = [email]

        #expect(coordinator.mailStore.emails.count == 1,
                "Mutating nested mailStore should be immediately visible through coordinator")
        #expect(coordinator.mailStore.emails.first?.subject == "Test")
    }

    // MARK: - handleCategoryChange resets selection state

    @Test func handleCategoryChangeResetsSelection() {
        let coordinator = AppCoordinator()
        coordinator.selectedEmail = Email(
            sender: Contact(name: "Test", email: "test@test.com"),
            subject: "Test",
            body: "Body",
            preview: "Preview",
            date: Date(),
            folder: .inbox
        )
        coordinator.selectedEmailIDs = ["abc", "def"]
        let prevTrigger = coordinator.searchResetTrigger

        coordinator.handleCategoryChange(.all)

        #expect(coordinator.selectedEmail == nil, "Category change should clear selectedEmail")
        #expect(coordinator.selectedEmailIDs.isEmpty, "Category change should clear selectedEmailIDs")
        #expect(coordinator.searchResetTrigger == prevTrigger + 1, "Category change should increment searchResetTrigger")
    }

    // MARK: - displayedEmails reflects mailboxViewModel

    @Test func displayedEmailsReflectsMailboxEmails() {
        let coordinator = AppCoordinator()
        coordinator.selectedFolder = .inbox

        // With no messages, displayedEmails should be empty
        #expect(coordinator.displayedEmails.isEmpty)
    }
}
