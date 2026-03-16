import Foundation

enum ComposeMode: Sendable {
    case new
    case reply(to: String, subject: String, quotedBody: String, replyToMessageID: String, threadID: String, parentMessageID: String? = nil, parentReferences: String? = nil)
    case replyAll(to: String, cc: String, subject: String, quotedBody: String, replyToMessageID: String, threadID: String, parentMessageID: String? = nil, parentReferences: String? = nil)
    case forward(subject: String, quotedBody: String)
}
