import Foundation

/// Resolves and manages email signatures based on send-as aliases.
struct SignatureResolver {

    // MARK: - HTML variants

    /// Resolves the raw HTML signature for a given preferred alias email.
    static func resolveHTML(preferredEmail: String, aliases: [GmailSendAs]) -> String {
        let alias: GmailSendAs?
        if !preferredEmail.isEmpty {
            alias = aliases.first(where: { $0.sendAsEmail == preferredEmail })
        } else {
            alias = aliases.first(where: { $0.isPrimary == true })
                ?? aliases.first(where: { $0.isDefault == true })
                ?? aliases.first
        }
        guard let sig = alias?.signature, !sig.isEmpty,
              !sig.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "<div class=\"serif-signature\">\(sig)</div>"
    }

    /// Returns the HTML signature for a specific alias email, with fallback.
    static func signatureHTMLForAlias(
        _ aliasEmail: String,
        aliases: [GmailSendAs],
        fallbackPreferredEmail: String
    ) -> String {
        if let alias = aliases.first(where: { $0.sendAsEmail == aliasEmail }),
           let sig = alias.signature, !sig.isEmpty,
           !sig.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "<div class=\"serif-signature\">\(sig)</div>"
        }
        return resolveHTML(preferredEmail: fallbackPreferredEmail, aliases: aliases)
    }

    /// Replaces the HTML signature block in the body.
    static func replaceHTMLSignature(
        in bodyHTML: String,
        currentSignature: String,
        newSignature: String
    ) -> (body: String, signature: String) {
        var updatedBody = bodyHTML
        if !currentSignature.isEmpty {
            // Try to find and replace the serif-signature div
            if let range = bodyHTML.range(of: currentSignature) {
                updatedBody = bodyHTML.replacingCharacters(in: range, with: newSignature)
            }
        } else if !newSignature.isEmpty {
            // Prepend signature
            updatedBody = "<br><br>\(newSignature)" + bodyHTML
        }
        return (updatedBody, newSignature)
    }
}
