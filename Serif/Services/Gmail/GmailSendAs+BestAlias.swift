extension Array where Element == GmailSendAs {
    /// Returns the `sendAsEmail` of the best matching alias for a received email,
    /// checking To recipients first, then Cc. Returns `nil` if no alias matches.
    func bestAlias(toRecipients: [String], ccRecipients: [String]) -> String? {
        // Priority 1: match in To
        for recipient in toRecipients {
            if let alias = first(where: { $0.sendAsEmail.caseInsensitiveCompare(recipient) == .orderedSame }) {
                return alias.sendAsEmail
            }
        }
        // Priority 2: match in Cc
        for recipient in ccRecipients {
            if let alias = first(where: { $0.sendAsEmail.caseInsensitiveCompare(recipient) == .orderedSame }) {
                return alias.sendAsEmail
            }
        }
        return nil
    }
}
