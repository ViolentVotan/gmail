import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// Creates and manages NSUserActivity instances so Siri and Apple Intelligence
/// can reason about the email currently displayed on screen.
enum UserActivityManager {

    static let viewEmailActivityType = "com.vikingz.vik.viewEmail"

    /// Build an NSUserActivity for the given email, suitable for Siri onscreen awareness.
    static func activity(for email: Email, accountID: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: viewEmailActivityType)
        activity.title = email.subject
        activity.isEligibleForSearch = true
        activity.isEligibleForHandoff = false
        activity.targetContentIdentifier = email.gmailMessageID

        // Searchable attributes let Siri describe the onscreen content
        let attributes = CSSearchableItemAttributeSet(contentType: .emailMessage)
        attributes.subject = email.subject
        attributes.authorNames = [email.sender.name]
        attributes.authorEmailAddresses = [email.sender.email]
        attributes.contentDescription = String(email.preview.prefix(300))
        attributes.contentCreationDate = email.date
        if !email.recipients.isEmpty {
            attributes.recipientNames = email.recipients.map(\.name)
            attributes.recipientEmailAddresses = email.recipients.map(\.email)
        }
        activity.contentAttributeSet = attributes

        activity.userInfo = [
            "messageId": email.gmailMessageID ?? "",
            "accountID": accountID
        ]

        return activity
    }
}
