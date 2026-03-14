import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct EmailDragItem: Codable, Transferable, Identifiable, Sendable {
    let messageIds: [String]
    let accountID: String

    var id: String { messageIds.first ?? accountID }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .emailDragItem)
    }
}

extension UTType {
    static let emailDragItem = UTType(exportedAs: "com.vikingz.serif.email-drag-item")
}
