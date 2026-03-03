import XCTest
import Combine
@testable import Serif

@MainActor
final class AppCoordinatorTests: XCTestCase {

    // MARK: - Child objectWillChange forwarding

    /// Regression test: when mailboxViewModel publishes changes,
    /// AppCoordinator must forward objectWillChange so SwiftUI re-renders.
    /// Bug: category switch required double-click because nested VM changes
    /// didn't trigger view updates.
    func testMailboxViewModelChangesForwardToCoordinator() {
        let coordinator = AppCoordinator()
        let expectation = expectation(description: "Coordinator objectWillChange fires")

        let cancellable = coordinator.objectWillChange
            .sink { _ in expectation.fulfill() }

        // Mutate the nested mailboxViewModel — coordinator should forward the change
        coordinator.mailboxViewModel.isLoading = true

        waitForExpectations(timeout: 1)
        cancellable.cancel()
    }

    /// Regression test: mailStore changes must also be forwarded (drafts folder).
    func testMailStoreChangesForwardToCoordinator() {
        let coordinator = AppCoordinator()
        let expectation = expectation(description: "Coordinator objectWillChange fires from mailStore")

        let cancellable = coordinator.objectWillChange
            .sink { _ in expectation.fulfill() }

        // Mutate the nested mailStore — coordinator should forward the change
        coordinator.mailStore.objectWillChange.send()

        waitForExpectations(timeout: 1)
        cancellable.cancel()
    }

    // MARK: - handleCategoryChange resets selection state

    func testHandleCategoryChangeResetsSelection() {
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

        XCTAssertNil(coordinator.selectedEmail, "Category change should clear selectedEmail")
        XCTAssertTrue(coordinator.selectedEmailIDs.isEmpty, "Category change should clear selectedEmailIDs")
        XCTAssertEqual(coordinator.searchResetTrigger, prevTrigger + 1, "Category change should increment searchResetTrigger")
    }

    // MARK: - displayedEmails reflects mailboxViewModel

    func testDisplayedEmailsReflectsMailboxEmails() {
        let coordinator = AppCoordinator()
        coordinator.selectedFolder = .inbox

        // With no messages, displayedEmails should be empty
        XCTAssertTrue(coordinator.displayedEmails.isEmpty)
    }
}
