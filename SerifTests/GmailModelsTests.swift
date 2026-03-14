import Testing
import Foundation
@testable import Serif

@Suite struct GmailModelsTests {

    // MARK: - GmailMessageListResponse

    @Test func decodeMessageListResponse() throws {
        let json = """
        {
            "messages": [
                {"id": "msg001", "threadId": "thread001"},
                {"id": "msg002", "threadId": "thread002"}
            ],
            "nextPageToken": "token_abc",
            "resultSizeEstimate": 42
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GmailMessageListResponse.self, from: json)
        #expect(response.messages?.count == 2)
        #expect(response.messages?[0].id == "msg001")
        #expect(response.messages?[0].threadId == "thread001")
        #expect(response.messages?[1].id == "msg002")
        #expect(response.nextPageToken == "token_abc")
        #expect(response.resultSizeEstimate == 42)
    }

    @Test func decodeMessageListResponseEmptyMessages() throws {
        let json = """
        {
            "resultSizeEstimate": 0
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GmailMessageListResponse.self, from: json)
        #expect(response.messages == nil)
        #expect(response.nextPageToken == nil)
        #expect(response.resultSizeEstimate == 0)
    }

    // MARK: - GmailMessage

    @Test func decodeGmailMessageFull() throws {
        let json = """
        {
            "id": "18abc123",
            "threadId": "18abc000",
            "labelIds": ["INBOX", "UNREAD", "STARRED"],
            "snippet": "Hey, just checking in...",
            "internalDate": "1700000000000",
            "sizeEstimate": 4096,
            "historyId": "999",
            "payload": {
                "partId": "0",
                "mimeType": "multipart/alternative",
                "headers": [
                    {"name": "From", "value": "Alice <alice@example.com>"},
                    {"name": "To", "value": "bob@example.com"},
                    {"name": "Cc", "value": "charlie@example.com"},
                    {"name": "Subject", "value": "Hello World"},
                    {"name": "Reply-To", "value": "alice-reply@example.com"},
                    {"name": "Message-ID", "value": "<abc@mail.example.com>"},
                    {"name": "In-Reply-To", "value": "<prev@mail.example.com>"}
                ],
                "body": {"size": 0},
                "parts": [
                    {
                        "partId": "0.0",
                        "mimeType": "text/plain",
                        "body": {"size": 25, "data": "SGVsbG8gV29ybGQ"}
                    },
                    {
                        "partId": "0.1",
                        "mimeType": "text/html",
                        "body": {"size": 40, "data": "PGI-SGVsbG8gV29ybGQ8L2I-"}
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(GmailMessage.self, from: json)

        #expect(msg.id == "18abc123")
        #expect(msg.threadId == "18abc000")
        #expect(msg.labelIds == ["INBOX", "UNREAD", "STARRED"])
        #expect(msg.snippet == "Hey, just checking in...")
        #expect(msg.internalDate == "1700000000000")
        #expect(msg.sizeEstimate == 4096)
        #expect(msg.historyId == "999")
        #expect(msg.payload?.mimeType == "multipart/alternative")
        #expect(msg.payload?.parts?.count == 2)
    }

    @Test func decodeGmailMessageMinimal() throws {
        let json = """
        {
            "id": "minimal_id",
            "threadId": "minimal_thread"
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(GmailMessage.self, from: json)
        #expect(msg.id == "minimal_id")
        #expect(msg.threadId == "minimal_thread")
        #expect(msg.labelIds == nil)
        #expect(msg.snippet == nil)
        #expect(msg.internalDate == nil)
        #expect(msg.payload == nil)
        #expect(msg.sizeEstimate == nil)
    }

    // MARK: - GmailMessage.header()

    @Test func headerNamedIsCaseInsensitive() throws {
        let msg = makeMessage(headers: [
            ("From", "alice@example.com"),
            ("Subject", "Test Subject"),
            ("X-Custom-Header", "custom-value")
        ])

        #expect(msg.header(named: "from") == "alice@example.com")
        #expect(msg.header(named: "FROM") == "alice@example.com")
        #expect(msg.header(named: "From") == "alice@example.com")
        #expect(msg.header(named: "subject") == "Test Subject")
        #expect(msg.header(named: "x-custom-header") == "custom-value")
        #expect(msg.header(named: "Nonexistent") == nil)
    }

    // MARK: - Computed Properties: from, subject, to, cc

    @Test func fromSubjectToCC() throws {
        let msg = makeMessage(headers: [
            ("From", "Alice <alice@example.com>"),
            ("Subject", "Important Meeting"),
            ("To", "bob@example.com"),
            ("Cc", "charlie@example.com")
        ])

        #expect(msg.from == "Alice <alice@example.com>")
        #expect(msg.subject == "Important Meeting")
        #expect(msg.to == "bob@example.com")
        #expect(msg.cc == "charlie@example.com")
    }

    @Test func subjectFallbackWhenMissing() throws {
        let msg = makeMessage(headers: [])
        #expect(msg.subject == "(no subject)")
        #expect(msg.from == "")
        #expect(msg.to == "")
        #expect(msg.cc == "")
    }

    @Test func replyToFallsBackToFrom() throws {
        let msg = makeMessage(headers: [
            ("From", "sender@example.com")
        ])
        #expect(msg.replyTo == "sender@example.com")

        let msgWithReplyTo = makeMessage(headers: [
            ("From", "sender@example.com"),
            ("Reply-To", "reply@example.com")
        ])
        #expect(msgWithReplyTo.replyTo == "reply@example.com")
    }

    // MARK: - Date

    @Test func dateConversion() throws {
        // 1700000000000 ms = Nov 14, 2023 22:13:20 UTC
        let json = """
        {
            "id": "date_test",
            "threadId": "t1",
            "internalDate": "1700000000000"
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(GmailMessage.self, from: json)
        let date = try #require(msg.date)

        #expect(abs(date.timeIntervalSince1970 - 1_700_000_000) < 1)
    }

    @Test func dateNilWhenMissing() throws {
        let json = """
        {"id": "no_date", "threadId": "t1"}
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(GmailMessage.self, from: json)
        #expect(msg.date == nil)
    }

    // MARK: - Label Flags: isUnread, isStarred, isDraft

    @Test func isUnread() throws {
        let unread = makeMessage(labelIds: ["INBOX", "UNREAD"])
        #expect(unread.isUnread)

        let read = makeMessage(labelIds: ["INBOX"])
        #expect(!read.isUnread)

        let noLabels = makeMessage(labelIds: nil)
        #expect(!noLabels.isUnread)
    }

    @Test func isStarred() throws {
        let starred = makeMessage(labelIds: ["STARRED"])
        #expect(starred.isStarred)

        let notStarred = makeMessage(labelIds: ["INBOX"])
        #expect(!notStarred.isStarred)
    }

    @Test func isDraft() throws {
        let draft = makeMessage(labelIds: ["DRAFT"])
        #expect(draft.isDraft)

        let notDraft = makeMessage(labelIds: ["INBOX"])
        #expect(!notDraft.isDraft)
    }

    // MARK: - Mailing List Detection

    @Test func isFromMailingListWithListUnsubscribe() throws {
        let msg = makeMessage(headers: [
            ("List-Unsubscribe", "<https://example.com/unsub>")
        ])
        #expect(msg.isFromMailingList)
    }

    @Test func isFromMailingListWithListId() throws {
        let msg = makeMessage(headers: [
            ("List-Id", "<news.example.com>")
        ])
        #expect(msg.isFromMailingList)
    }

    @Test func isNotFromMailingList() throws {
        let msg = makeMessage(headers: [
            ("From", "person@example.com")
        ])
        #expect(!msg.isFromMailingList)
    }

    // MARK: - Unsubscribe URL Parsing

    @Test func unsubscribeURLPrefersHTTPS() throws {
        let msg = makeMessage(headers: [
            ("List-Unsubscribe", "<mailto:unsub@example.com>, <https://example.com/unsub?id=123>")
        ])
        #expect(msg.unsubscribeURL?.absoluteString == "https://example.com/unsub?id=123")
    }

    @Test func unsubscribeURLFallsBackToMailto() throws {
        let msg = makeMessage(headers: [
            ("List-Unsubscribe", "<mailto:unsub@example.com>")
        ])
        #expect(msg.unsubscribeURL?.scheme == "mailto")
    }

    @Test func unsubscribeURLNilWhenNoHeader() throws {
        let msg = makeMessage(headers: [])
        #expect(msg.unsubscribeURL == nil)
    }

    // MARK: - One-Click Unsubscribe

    @Test func supportsOneClickUnsubscribe() throws {
        let msg = makeMessage(headers: [
            ("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
        ])
        #expect(msg.supportsOneClickUnsubscribe)
    }

    @Test func doesNotSupportOneClickUnsubscribeWithoutHeader() throws {
        let msg = makeMessage(headers: [])
        #expect(!msg.supportsOneClickUnsubscribe)
    }

    // MARK: - Body Extraction

    @Test func htmlBodyExtraction() throws {
        let msg = makeMessage(headers: [], htmlBodyData: "PGI-SGVsbG8gV29ybGQ8L2I-")
        #expect(msg.htmlBody != nil)
        #expect(msg.htmlBody?.contains("Hello World") == true)
    }

    @Test func plainBodyExtraction() throws {
        let msg = makeMessage(headers: [], plainBodyData: "SGVsbG8gV29ybGQ")
        #expect(msg.plainBody != nil)
        #expect(msg.plainBody == "Hello World")
    }

    @Test func bodyPrefersHtmlOverPlain() throws {
        let msg = makeMessage(
            headers: [],
            htmlBodyData: "PGI-SFRNTA8L2I-",  // <b>HTML</b>
            plainBodyData: "UGxhaW4"            // Plain
        )
        // body should prefer htmlBody
        #expect(msg.htmlBody != nil)
    }

    // MARK: - FromDomain

    @Test func fromDomainWithAngleBrackets() throws {
        let msg = makeMessage(headers: [
            ("From", "Alice Smith <alice@example.com>")
        ])
        #expect(msg.fromDomain == "example.com")
    }

    @Test func fromDomainPlainEmail() throws {
        let msg = makeMessage(headers: [
            ("From", "bob@company.co.uk")
        ])
        #expect(msg.fromDomain == "company.co.uk")
    }

    // MARK: - Security: mailedBy, signedBy, encryptionInfo

    @Test func mailedByFromReturnPath() throws {
        let msg = makeMessage(headers: [
            ("Return-Path", "<bounce@sender.example.com>")
        ])
        #expect(msg.mailedBy == "sender.example.com")
    }

    @Test func signedByFromDKIM() throws {
        let msg = makeMessage(headers: [
            ("DKIM-Signature", "v=1; a=rsa-sha256; d=example.com; s=selector; b=abc123")
        ])
        #expect(msg.signedBy == "example.com")
    }

    @Test func encryptionInfoDetectsTLS() throws {
        let msg = makeMessage(headers: [
            ("Received", "from mail.example.com by mx.google.com with ESMTPS id abc")
        ])
        #expect(msg.encryptionInfo == "Standard encryption (TLS)")
    }

    @Test func encryptionInfoNilWithoutTLS() throws {
        let msg = makeMessage(headers: [
            ("Received", "from mail.example.com by mx.google.com with SMTP id abc")
        ])
        #expect(msg.encryptionInfo == nil)
    }

    // MARK: - Suspicious Sender

    @Test func isSuspiciousSenderMismatchedDomains() throws {
        let msg = makeMessage(headers: [
            ("From", "legit@trusted.com"),
            ("Return-Path", "<bounce@phishing.com>")
        ])
        #expect(msg.isSuspiciousSender)
    }

    @Test func isNotSuspiciousSenderMatchingDomains() throws {
        let msg = makeMessage(headers: [
            ("From", "alice@example.com"),
            ("Return-Path", "<bounce@example.com>")
        ])
        #expect(!msg.isSuspiciousSender)
    }

    // MARK: - HasPartsWithFilenames

    @Test func hasPartsWithFilenames() throws {
        let json = """
        {
            "id": "att_msg",
            "threadId": "t1",
            "payload": {
                "mimeType": "multipart/mixed",
                "body": {"size": 0},
                "parts": [
                    {
                        "mimeType": "text/plain",
                        "body": {"size": 10}
                    },
                    {
                        "filename": "report.pdf",
                        "mimeType": "application/pdf",
                        "body": {"size": 5000, "attachmentId": "att001"}
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(GmailMessage.self, from: json)
        #expect(msg.hasPartsWithFilenames)
        #expect(msg.attachmentParts.count == 1)
        #expect(msg.attachmentParts.first?.filename == "report.pdf")
    }

    // MARK: - GmailHistoryListResponse

    @Test func decodeHistoryListResponse() throws {
        let json = """
        {
            "history": [
                {
                    "id": "12345",
                    "messagesAdded": [
                        {"message": {"id": "msg_new", "threadId": "t_new"}}
                    ],
                    "labelsAdded": [
                        {"message": {"id": "msg1", "threadId": "t1"}, "labelIds": ["STARRED"]}
                    ],
                    "labelsRemoved": [
                        {"message": {"id": "msg2", "threadId": "t2"}, "labelIds": ["UNREAD"]}
                    ]
                }
            ],
            "nextPageToken": "hist_token",
            "historyId": "99999"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GmailHistoryListResponse.self, from: json)
        #expect(response.historyId == "99999")
        #expect(response.nextPageToken == "hist_token")
        #expect(response.history?.count == 1)

        let record = try #require(response.history?.first)
        #expect(record.id == "12345")
        #expect(record.messagesAdded?.count == 1)
        #expect(record.messagesAdded?.first?.message.id == "msg_new")
        #expect(record.labelsAdded?.count == 1)
        #expect(record.labelsAdded?.first?.labelIds == ["STARRED"])
        #expect(record.labelsRemoved?.count == 1)
        #expect(record.labelsRemoved?.first?.labelIds == ["UNREAD"])
    }

    // MARK: - GmailLabel

    @Test func decodeGmailLabel() throws {
        let json = """
        {
            "id": "Label_42",
            "name": "work/projects",
            "type": "user",
            "messagesTotal": 150,
            "messagesUnread": 3,
            "threadsTotal": 80,
            "threadsUnread": 2,
            "color": {
                "textColor": "#ffffff",
                "backgroundColor": "#0000ff"
            }
        }
        """.data(using: .utf8)!

        let label = try JSONDecoder().decode(GmailLabel.self, from: json)
        #expect(label.id == "Label_42")
        #expect(label.name == "work/projects")
        #expect(label.displayName == "projects")
        #expect(label.type == "user")
        #expect(label.messagesTotal == 150)
        #expect(label.messagesUnread == 3)
        #expect(label.color?.backgroundColor == "#0000ff")
    }

    @Test func gmailLabelIsSystemLabel() throws {
        let inbox = GmailLabel(id: "INBOX", name: "INBOX", type: "system",
                               messagesTotal: nil, messagesUnread: nil,
                               threadsTotal: nil, threadsUnread: nil, color: nil,
                               labelListVisibility: nil, messageListVisibility: nil)
        #expect(inbox.isSystemLabel)

        let custom = GmailLabel(id: "Label_1", name: "MyLabel", type: "user",
                                messagesTotal: nil, messagesUnread: nil,
                                threadsTotal: nil, threadsUnread: nil, color: nil,
                               labelListVisibility: nil, messageListVisibility: nil)
        #expect(!custom.isSystemLabel)
    }

    @Test func gmailLabelDisplayNameNoSlash() throws {
        let label = GmailLabel(id: "L1", name: "SimpleLabel", type: nil,
                               messagesTotal: nil, messagesUnread: nil,
                               threadsTotal: nil, threadsUnread: nil, color: nil,
                               labelListVisibility: nil, messageListVisibility: nil)
        #expect(label.displayName == "SimpleLabel")
    }

    @Test func gmailLabelResolvedColors() throws {
        let withColor = GmailLabel(
            id: "L1", name: "Colored",
            type: nil, messagesTotal: nil, messagesUnread: nil,
            threadsTotal: nil, threadsUnread: nil,
            color: GmailLabelColor(textColor: "#ff0000", backgroundColor: "#00ff00"),
            labelListVisibility: nil, messageListVisibility: nil
        )
        #expect(withColor.resolvedBgColor == "#00ff00")
        #expect(withColor.resolvedTextColor == "#ff0000")

        let withoutColor = GmailLabel(id: "L2", name: "NoColor", type: nil,
                                      messagesTotal: nil, messagesUnread: nil,
                                      threadsTotal: nil, threadsUnread: nil, color: nil,
                               labelListVisibility: nil, messageListVisibility: nil)
        // Should fall back to palette - just verify it returns a non-empty string
        #expect(!withoutColor.resolvedBgColor.isEmpty)
        #expect(!withoutColor.resolvedTextColor.isEmpty)
        #expect(withoutColor.resolvedBgColor.hasPrefix("#"))
    }

    // MARK: - GmailProfile

    @Test func decodeGmailProfile() throws {
        let json = """
        {
            "emailAddress": "user@gmail.com",
            "messagesTotal": 12345,
            "threadsTotal": 6789,
            "historyId": "55555"
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(GmailProfile.self, from: json)
        #expect(profile.emailAddress == "user@gmail.com")
        #expect(profile.messagesTotal == 12345)
        #expect(profile.threadsTotal == 6789)
        #expect(profile.historyId == "55555")
    }

    // MARK: - GmailThread

    @Test func decodeGmailThread() throws {
        let json = """
        {
            "id": "thread_001",
            "historyId": "777",
            "messages": [
                {"id": "m1", "threadId": "thread_001"},
                {"id": "m2", "threadId": "thread_001"}
            ]
        }
        """.data(using: .utf8)!

        let thread = try JSONDecoder().decode(GmailThread.self, from: json)
        #expect(thread.id == "thread_001")
        #expect(thread.historyId == "777")
        #expect(thread.messages?.count == 2)
    }

    // MARK: - GmailDraft

    @Test func decodeGmailDraftListResponse() throws {
        let json = """
        {
            "drafts": [
                {"id": "d1", "message": {"id": "m1", "threadId": "t1"}},
                {"id": "d2"}
            ],
            "resultSizeEstimate": 2
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GmailDraftListResponse.self, from: json)
        #expect(response.drafts?.count == 2)
        #expect(response.drafts?[0].id == "d1")
        #expect(response.drafts?[0].message?.id == "m1")
        #expect(response.drafts?[1].message == nil)
    }

    // MARK: - Helpers

    /// Creates a GmailMessage with the specified headers, using JSON decoding.
    private func makeMessage(
        headers: [(String, String)],
        labelIds: [String]? = nil,
        htmlBodyData: String? = nil,
        plainBodyData: String? = nil
    ) -> GmailMessage {
        let headersJSON = headers.map { """
            {"name": "\($0.0)", "value": "\($0.1)"}
        """ }.joined(separator: ",")

        var partsJSON = ""
        var partsArray: [String] = []
        if let html = htmlBodyData {
            partsArray.append("""
                {"partId": "0.1", "mimeType": "text/html", "body": {"size": 100, "data": "\(html)"}}
            """)
        }
        if let plain = plainBodyData {
            partsArray.append("""
                {"partId": "0.0", "mimeType": "text/plain", "body": {"size": 50, "data": "\(plain)"}}
            """)
        }
        if !partsArray.isEmpty {
            partsJSON = ", \"parts\": [\(partsArray.joined(separator: ","))]"
        }

        let labelIdsJSON: String
        if let ids = labelIds {
            labelIdsJSON = ", \"labelIds\": [\(ids.map { "\"\($0)\"" }.joined(separator: ","))]"
        } else {
            labelIdsJSON = ""
        }

        let json = """
        {
            "id": "test_msg",
            "threadId": "test_thread"
            \(labelIdsJSON),
            "payload": {
                "mimeType": "multipart/alternative",
                "headers": [\(headersJSON)],
                "body": {"size": 0}
                \(partsJSON)
            }
        }
        """.data(using: .utf8)!

        return try! JSONDecoder().decode(GmailMessage.self, from: json)
    }

    /// Creates a GmailMessage with only labelIds set, using JSON decoding.
    private func makeMessage(labelIds: [String]?) -> GmailMessage {
        let labelIdsJSON: String
        if let ids = labelIds {
            labelIdsJSON = ", \"labelIds\": [\(ids.map { "\"\($0)\"" }.joined(separator: ","))]"
        } else {
            labelIdsJSON = ""
        }

        let json = """
        {
            "id": "test_msg",
            "threadId": "test_thread"
            \(labelIdsJSON)
        }
        """.data(using: .utf8)!

        return try! JSONDecoder().decode(GmailMessage.self, from: json)
    }
}
