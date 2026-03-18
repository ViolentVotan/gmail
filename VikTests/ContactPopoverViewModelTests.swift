import Testing
import AppKit
@testable import Vik

@Suite("ContactPopoverViewModel")
struct ContactPopoverViewModelTests {
    @Test("Known contact sets isKnownContact and resourceName")
    @MainActor
    func knownContactLoadsFromDB() async {
        let contact = Contact(name: "Jane", email: "jane@example.com")
        let vm = ContactPopoverViewModel(
            contact: contact,
            message: nil,
            accountID: "test-account",
            composeTo: { _ in },
            searchSender: { _ in }
        )
        #expect(vm.isKnownContact == false)
        #expect(vm.isEnriching == false)
    }

    @Test("Copy email puts address on pasteboard")
    @MainActor
    func copyEmail() {
        let contact = Contact(name: "Jane", email: "jane@example.com")
        let vm = ContactPopoverViewModel(
            contact: contact,
            message: nil,
            accountID: "test-account",
            composeTo: { _ in },
            searchSender: { _ in }
        )
        vm.copyEmail()
        let copied = NSPasteboard.general.string(forType: .string)
        #expect(copied == "jane@example.com")
    }

    @Test("Compose action calls composeTo closure")
    @MainActor
    func composeCallsClosure() {
        var composedTo: String?
        let contact = Contact(name: "Jane", email: "jane@example.com")
        let vm = ContactPopoverViewModel(
            contact: contact,
            message: nil,
            accountID: "test-account",
            composeTo: { composedTo = $0 },
            searchSender: { _ in }
        )
        vm.composeEmail()
        #expect(composedTo == "jane@example.com")
    }

    @Test("Search action calls searchSender closure")
    @MainActor
    func searchCallsClosure() {
        var searchedFor: String?
        let contact = Contact(name: "Jane", email: "jane@example.com")
        let vm = ContactPopoverViewModel(
            contact: contact,
            message: nil,
            accountID: "test-account",
            composeTo: { _ in },
            searchSender: { searchedFor = $0 }
        )
        vm.searchEmails()
        #expect(searchedFor == "jane@example.com")
    }

    @Test("Enrichment cache returns cached value within TTL")
    @MainActor
    func enrichmentCacheHit() {
        let details = PersonDetails(organization: "Acme", title: nil, phoneNumber: nil, location: nil)
        ContactPopoverViewModel.cachePersonDetails(details, forEmail: "cached@test.com")
        let cached = ContactPopoverViewModel.cachedPersonDetails(forEmail: "cached@test.com")
        #expect(cached?.organization == "Acme")
    }
}
