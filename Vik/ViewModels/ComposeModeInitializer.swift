import Foundation

/// Holds the field values produced by applying a ComposeMode.
struct ComposeModeFields {
    var to: String = ""
    var cc: String = ""
    var showCc: Bool = false
    var subject: String = ""
    var bodyHTML: String = ""
    var currentSignatureHTML: String = ""
    var threadID: String? = nil
    var replyToMessageID: String? = nil
    var parentMessageID: String? = nil
    var parentReferences: String? = nil
}

/// Populates compose field values based on a ComposeMode and signature settings.
struct ComposeModeInitializer {

    /// Applies the given compose mode and returns the resulting field values.
    static func apply(
        mode: ComposeMode,
        signatureForNew: String,
        signatureForReply: String,
        aliases: [GmailSendAs]
    ) -> ComposeModeFields {
        var fields = ComposeModeFields()

        switch mode {
        case .new:
            let sig = SignatureResolver.resolveHTML(preferredEmail: signatureForNew, aliases: aliases)
            if !sig.isEmpty {
                fields.currentSignatureHTML = sig
                fields.bodyHTML = "<br><br>\(sig)"
            }

        case .newTo(let to):
            fields.to = to
            let sig = SignatureResolver.resolveHTML(preferredEmail: signatureForNew, aliases: aliases)
            if !sig.isEmpty {
                fields.currentSignatureHTML = sig
                fields.bodyHTML = "<br><br>\(sig)"
            }

        case .reply(let replyTo, let replySubject, let quotedBody, let replyToMessageID, let threadID, let parentMessageID, let parentReferences):
            fields.to = replyTo
            fields.subject = replySubject.withReplyPrefix
            applyQuotedBody(&fields, signatureForReply: signatureForReply, aliases: aliases, quotedBody: quotedBody)
            applyThreading(&fields, threadID: threadID, replyToMessageID: replyToMessageID, parentMessageID: parentMessageID, parentReferences: parentReferences)

        case .replyAll(let replyTo, let replyCc, let replySubject, let quotedBody, let replyToMessageID, let threadID, let parentMessageID, let parentReferences):
            fields.to = replyTo
            fields.cc = replyCc
            fields.showCc = !replyCc.isEmpty
            fields.subject = replySubject.withReplyPrefix
            applyQuotedBody(&fields, signatureForReply: signatureForReply, aliases: aliases, quotedBody: quotedBody)
            applyThreading(&fields, threadID: threadID, replyToMessageID: replyToMessageID, parentMessageID: parentMessageID, parentReferences: parentReferences)

        case .forward(let to, let fwdSubject, let quotedBody):
            fields.to = to ?? ""
            fields.subject = fwdSubject.withForwardPrefix
            applyQuotedBody(&fields, signatureForReply: signatureForReply, aliases: aliases, quotedBody: quotedBody)
        }

        return fields
    }

    private static func applyQuotedBody(
        _ fields: inout ComposeModeFields,
        signatureForReply: String,
        aliases: [GmailSendAs],
        quotedBody: String
    ) {
        let sig = SignatureResolver.resolveHTML(preferredEmail: signatureForReply, aliases: aliases)
        fields.currentSignatureHTML = sig
        fields.bodyHTML = sig.isEmpty ? "<br><br>\(quotedBody)" : "<br><br>\(sig)<br>\(quotedBody)"
    }

    private static func applyThreading(
        _ fields: inout ComposeModeFields,
        threadID: String?,
        replyToMessageID: String?,
        parentMessageID: String?,
        parentReferences: String?
    ) {
        fields.threadID = threadID
        fields.replyToMessageID = replyToMessageID
        fields.parentMessageID = parentMessageID
        fields.parentReferences = parentReferences
    }
}
