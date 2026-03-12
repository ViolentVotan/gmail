import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct EmailDragItem: Codable, Transferable {
    let messageIds: [String]
    let accountID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .emailDragItem)
    }
}

extension UTType {
    static let emailDragItem = UTType(exportedAs: "com.genyus.serif.email-drag-item")
}
