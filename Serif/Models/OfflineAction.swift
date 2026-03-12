import Foundation

struct OfflineAction: Codable, Identifiable, Sendable {
    let id: UUID
    let actionType: ActionType
    let messageIds: [String]
    let accountID: String
    let timestamp: Date
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        actionType: ActionType,
        messageIds: [String],
        accountID: String,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.actionType = actionType
        self.messageIds = messageIds
        self.accountID = accountID
        self.timestamp = timestamp
        self.metadata = metadata
    }

    enum ActionType: String, Codable, Sendable {
        case archive
        case trash
        case markRead
        case markUnread
        case star
        case unstar
        case spam
        case addLabel
        case removeLabel
    }
}
