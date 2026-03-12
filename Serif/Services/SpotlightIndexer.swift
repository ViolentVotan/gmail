import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    private let index = CSSearchableIndex.default()
    private var indexedCount = 0
    private let maxIndexed = 1000

    func indexEmail(_ email: Email) {
        let attributes = CSSearchableItemAttributeSet(contentType: .emailMessage)
        attributes.subject = email.subject
        attributes.authorNames = [email.sender.name]
        attributes.textContent = email.preview
        attributes.contentCreationDate = email.date
        attributes.contentDescription = email.folder.rawValue

        let item = CSSearchableItem(
            uniqueIdentifier: "email-\(email.id)",
            domainIdentifier: "com.serif.emails",
            attributeSet: attributes
        )
        item.expirationDate = Calendar.current.date(byAdding: .day, value: 30, to: Date())

        Task.detached {
            try? await CSSearchableIndex.default().indexSearchableItems([item])
        }

        indexedCount += 1
        if indexedCount > maxIndexed {
            pruneAllEntries()
        }
    }

    private func pruneAllEntries() {
        Task.detached {
            try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["com.serif.emails"])
        }
        indexedCount = 0
    }
}
