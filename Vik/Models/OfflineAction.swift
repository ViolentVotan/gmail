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

    enum ActionType: Codable, Sendable, Equatable {
        case archive
        case trash
        case untrash
        case markRead
        case markUnread
        case star
        case unstar
        case spam
        case addLabel
        case removeLabel
        case deletePermanently
        case send(rawBase64URL: String, threadID: String?)

        // MARK: - Codable

        private enum CodingKeys: String, CodingKey {
            case type
            case rawBase64URL
            case threadID
        }

        init(from decoder: Decoder) throws {
            // Support legacy single-string format
            if let container = try? decoder.singleValueContainer(),
               let raw = try? container.decode(String.self) {
                switch raw {
                case "archive":           self = .archive
                case "trash":             self = .trash
                case "untrash":           self = .untrash
                case "markRead":          self = .markRead
                case "markUnread":        self = .markUnread
                case "star":              self = .star
                case "unstar":            self = .unstar
                case "spam":              self = .spam
                case "addLabel":          self = .addLabel
                case "removeLabel":       self = .removeLabel
                case "deletePermanently": self = .deletePermanently
                default:
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Unknown ActionType: \(raw)"
                    )
                }
                return
            }

            // Keyed format for cases with associated values
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "archive":           self = .archive
            case "trash":             self = .trash
            case "untrash":           self = .untrash
            case "markRead":          self = .markRead
            case "markUnread":        self = .markUnread
            case "star":              self = .star
            case "unstar":            self = .unstar
            case "spam":              self = .spam
            case "addLabel":          self = .addLabel
            case "removeLabel":       self = .removeLabel
            case "deletePermanently": self = .deletePermanently
            case "send":
                let rawBase64URL = try container.decode(String.self, forKey: .rawBase64URL)
                let threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
                self = .send(rawBase64URL: rawBase64URL, threadID: threadID)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown ActionType: \(type)"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .send(let rawBase64URL, let threadID):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("send", forKey: .type)
                try container.encode(rawBase64URL, forKey: .rawBase64URL)
                try container.encodeIfPresent(threadID, forKey: .threadID)
            default:
                var container = encoder.singleValueContainer()
                try container.encode(stringValue)
            }
        }

        private var stringValue: String {
            switch self {
            case .archive:           "archive"
            case .trash:             "trash"
            case .untrash:           "untrash"
            case .markRead:          "markRead"
            case .markUnread:        "markUnread"
            case .star:              "star"
            case .unstar:            "unstar"
            case .spam:              "spam"
            case .addLabel:          "addLabel"
            case .removeLabel:       "removeLabel"
            case .deletePermanently: "deletePermanently"
            case .send:              "send"
            }
        }
    }
}
