import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedEmailTags {
    @Guide(description: "true if the sender expects a reply from the reader")
    var needsReply: Bool
    @Guide(description: "true if this is purely informational with no action needed")
    var fyiOnly: Bool
    @Guide(description: "true if a specific deadline or due date is mentioned")
    var hasDeadline: Bool
    @Guide(description: "true if this involves money: invoice, receipt, payment, billing")
    var financial: Bool
}
#endif

struct EmailTags: Codable, Sendable, Equatable {
    var needsReply: Bool = false
    var fyiOnly: Bool = false
    var hasDeadline: Bool = false
    var financial: Bool = false

    var activeTags: [(label: String, color: String)] {
        var tags: [(String, String)] = []
        if needsReply  { tags.append(("Reply needed", "blue")) }
        if hasDeadline { tags.append(("Deadline", "red")) }
        if financial   { tags.append(("Financial", "green")) }
        if fyiOnly     { tags.append(("FYI", "gray")) }
        return tags
    }
}
