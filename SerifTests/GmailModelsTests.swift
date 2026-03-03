import XCTest
@testable import Serif

final class GmailModelsTests: XCTestCase {

    // MARK: - GmailMessageListResponse

    func testDecodeMessageListResponse() throws {
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
        XCTAssertEqual(response.messages?.count, 2)
        XCTAssertEqual(response.messages?[0].id, "msg001")
        XCTAssertEqual(response.messages?[0].threadId, "thread001")
        XCTAssertEqual(response.messages?[1].id, "msg002")
        XCTAssertEqual(response.nextPageToken, "token_abc")
        XCTAssertEqual(response.resultSizeEstimate, 42)
    }

    func testDecodeMessageListResponseEmptyMessages() throws {
        let json = """
        {
            "resultSizeEstimate": 0
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GmailMessageListResponse.self, from: json)
        XCTAssertNil(response.messages)
        XCTAssertNil(response.nextPageToken)
        XCTAssertEqual(response.resultSizeEstimate, 0)
    }

    // MARK: - GmailMessage

    func testDecodeGmailMessageFull() throws {
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

        XCTAssertEqual(msg.id, "18abc123")
        XCTAssertEqual(msg.threadId, "18abc000")
        XCTAssertEqual(msg.labelIds, ["INBOX", "UNREAD", "STARRED"])
        XCTAssertEqual(msg.snippet, "Hey, just checking in...")
        XCTAssertEqual(msg.internalDate, "1700000000000")
        XCTAssertEqual(msg.sizeEstimate, 4096)
        XCTAssertEqual(msg.historyId, "999")
        XCTAssertEqual(msg.payload?.mimeType, "multipart/alternative")
        XCTAssertEqual(msg.payload?.parts?.count, 2)
    }

    func testDecodeGmailMessageMinimal() throws {
        let json = """
        {
            "id": "minimal_id",
            "threadId": "minimal_thread"
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(GmailMessage.self, from: json)
        XCTAssertEqual(msg.id, "minimal_id")
        XCTAssertEqual(msg.threadId, "minimal_thread")
        XCTAssertNil(msg.labelIds)
        XCTAssertNil(msg.snippet)
        XCTAssertNil(msg.internalDate)
        XCTAssertNil(msg.payload)
        XCTAssertNil(msg.sizeEstimate)
    }

    // MARK: - GmailMessage.header()

    func testHeaderNamedIsCaseInsensitive() throws {
        let msg = makeMessage(headers: [
            ("From", "alice@example.com"),
            ("Subject", "Test Subject"),
            ("X-Custom-Header", "custom-value")
        ])

        XCTAssertEqual(msg.header(named: "from"), "alice@example.com")
        XCTAssertEqual(msg.header(named: "FROM"), "alice@example.com")
        XCTAssertEqual(msg.header(named: "From"), "alice@example.com")
        XCTAssertEqual(msg.header(named: "subject"), "Test Subject")
        XCTAssertEqual(msg.header(named: "x-custom-header"), "custom-value")
        XCTAssertNil(msg.header(named: "Nonexistent"))
    }

    // MARK: - Computed Properties: from, subject, to, cc

    func testFromSubjectToCC() throws {
        let msg = makeMessage(headers: [
            ("From", "Alice <alice@example.com>"),
            ("Subject", "Important Meeting"),
            ("To", "bob@example.com"),
            ("Cc", "charlie@example.com")
        ])

        XCTAssertEqual(msg.from, "Alice <alice@example.com>")
        XCTAssertEqual(msg.subject, "Important Meeting")
        XCTAssertEqual(msg.to, "bob@example.com")
        XCTAssertEqual(msg.cc, "charlie@example.com")
    }

    func testSubjectFallbackWhenMissing() throws {
        let msg = makeMessage(headers: [])
        XCTAssertEqual(msg.subject, "(no subject)")
        XCTAssertEqual(msg.from, "")
        XCTAssertEqual(msg.to, "")
        XCTAssertEqual(msg.cc, "")
    }

    func testReplyToFallsBackToFrom() throws {
        let msg = makeMessage(headers: [
            ("From", "sender@example.com")
        ])
        XCTAssertEqual(msg.replyTo, "sender@example.com")

        let msgWithReplyTo = makeMessage(headers: [
            ("From", "sender@example.com"),
            ("Reply-To", "reply@example.com")
        ])
        XCTAssertEqual(msgWithReplyTo.replyTo, "reply@example.com")
    }

    // MARK: - Date

    func testDateConversion() throws {
        // 1700000000000 ms = Nov 14, 2023 22:13:20 UTC
        let json = """
        {
            "id": "date_test",
            "threadId": "t1",
            "internalDate": "1700000000000"
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(GmailMessage.self, from: json)
        let date = try XCTUnwrap(msg.date)

        XCTAssertEqual(date.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    func testDateNilWhenMissing() throws {
        let json = """
        {"id": "no_date", "threadId": "t1"}
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(GmailMessage.self, from: json)
        XCTAssertNil(msg.date)
    }

    // MARK: - Label Flags: isUnread, isStarred, isDraft

    func testIsUnread() throws {
        let unread = makeMessage(labelIds: ["INBOX", "UNREAD"])
        XCTAssertTrue(unread.isUnread)

        let read = makeMessage(labelIds: ["INBOX"])
        XCTAssertFalse(read.isUnread)

        let noLabels = makeMessage(labelIds: nil)
        XCTAssertFalse(noLabels.isUnread)
    }

    func testIsStarred() throws {
        let starred = makeMessage(labelIds: ["STARRED"])
        XCTAssertTrue(starred.isStarred)

        let notStarred = makeMessage(labelIds: ["INBOX"])
        XCTAssertFalse(notStarred.isStarred)
    }

    func testIsDraft() throws {
        let draft = makeMessage(labelIds: ["DRAFT"])
        XCTAssertTrue(draft.isDraft)

        let notDraft = makeMessage(labelIds: ["INBOX"])
        XCTAssertFalse(notDraft.isDraft)
    }

    // MARK: - Mailing List Detection

    func testIsFromMailingListWithListUnsubscribe() throws {
        let msg = makeMessage(headers: [
            ("List-Unsubscribe", "<https://example.com/unsub>")
        ])
        XCTAssertTrue(msg.isFromMailingList)
    }

    func testIsFromMailingListWithListId() throws {
        let msg = makeMessage(headers: [
            ("List-Id", "<news.example.com>")
        ])
        XCTAssertTrue(msg.isFromMailingList)
    }

    func testIsNotFromMailingList() throws {
        let msg = makeMessage(headers: [
            ("From", "person@example.com")
        ])
        XCTAssertFalse(msg.isFromMailingList)
    }

    // MARK: - Unsubscribe URL Parsing

    func testUnsubscribeURLPrefersHTTPS() throws {
        let msg = makeMessage(headers: [
            ("List-Unsubscribe", "<mailto:unsub@example.com>, <https://example.com/unsub?id=123>")
        ])
        XCTAssertEqual(msg.unsubscribeURL?.absoluteString, "https://example.com/unsub?id=123")
    }

    func testUnsubscribeURLFallsBackToMailto() throws {
        let msg = makeMessage(headers: [
            ("List-Unsubscribe", "<mailto:unsub@example.com>")
        ])
        XCTAssertEqual(msg.unsubscribeURL?.scheme, "mailto")
    }

    func testUnsubscribeURLNilWhenNoHeader() throws {
        let msg = makeMessage(headers: [])
        XCTAssertNil(msg.unsubscribeURL)
    }

    // MARK: - One-Click Unsubscribe

    func testSupportsOneClickUnsubscribe() throws {
        let msg = makeMessage(headers: [
            ("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
        ])
        XCTAssertTrue(msg.supportsOneClickUnsubscribe)
    }

    func testDoesNotSupportOneClickUnsubscribeWithoutHeader() throws {
        let msg = makeMessage(headers: [])
        XCTAssertFalse(msg.supportsOneClickUnsubscribe)
    }

    // MARK: - Body Extraction

    func testHtmlBodyExtraction() throws {
        let msg = makeMessage(headers: [], htmlBodyData: "PGI-SGVsbG8gV29ybGQ8L2I-")
        XCTAssertNotNil(msg.htmlBody)
        XCTAssertTrue(msg.htmlBody?.contains("Hello World") == true)
    }

    func testPlainBodyExtraction() throws {
        let msg = makeMessage(headers: [], plainBodyData: "SGVsbG8gV29ybGQ")
        XCTAssertNotNil(msg.plainBody)
        XCTAssertEqual(msg.plainBody, "Hello World")
    }

    func testBodyPrefersHtmlOverPlain() throws {
        let msg = makeMessage(
            headers: [],
            htmlBodyData: "PGI-SFRNTA8L2I-",  // <b>HTML</b>
            plainBodyData: "UGxhaW4"            // Plain
        )
        // body should prefer htmlBody
        XCTAssertNotNil(msg.htmlBody)
    }

    // MARK: - FromDomain

    func testFromDomainWithAngleBrackets() throws {
        let msg = makeMessage(headers: [
            ("From", "Alice Smith <alice@example.com>")
        ])
        XCTAssertEqual(msg.fromDomain, "example.com")
    }

    func testFromDomainPlainEmail() throws {
        let msg = makeMessage(headers: [
            ("From", "bob@company.co.uk")
        ])
        XCTAssertEqual(msg.fromDomain, "company.co.uk")
    }

    // MARK: - Security: mailedBy, signedBy, encryptionInfo

    func testMailedByFromReturnPath() throws {
        let msg = makeMessage(headers: [
            ("Return-Path", "<bounce@sender.example.com>")
        ])
        XCTAssertEqual(msg.mailedBy, "sender.example.com")
    }

    func testSignedByFromDKIM() throws {
        let msg = makeMessage(headers: [
            ("DKIM-Signature", "v=1; a=rsa-sha256; d=example.com; s=selector; b=abc123")
        ])
        XCTAssertEqual(msg.signedBy, "example.com")
    }

    func testEncryptionInfoDetectsTLS() throws {
        let msg = makeMessage(headers: [
            ("Received", "from mail.example.com by mx.google.com with ESMTPS id abc")
        ])
        XCTAssertEqual(msg.encryptionInfo, "Standard encryption (TLS)")
    }

    func testEncryptionInfoNilWithoutTLS() throws {
        let msg = makeMessage(headers: [
            ("Received", "from mail.example.com by mx.google.com with SMTP id abc")
        ])
        XCTAssertNil(msg.encryptionInfo)
    }

    // MARK: - Suspicious Sender

    func testIsSuspiciousSenderMismatchedDomains() throws {
        let msg = makeMessage(headers: [
            ("From", "legit@trusted.com"),
            ("Return-Path", "<bounce@phishing.com>")
        ])
        XCTAssertTrue(msg.isSuspiciousSender)
    }

    func testIsNotSuspiciousSenderMatchingDomains() throws {
        let msg = makeMessage(headers: [
            ("From", "alice@example.com"),
            ("Return-Path", "<bounce@example.com>")
        ])
        XCTAssertFalse(msg.isSuspiciousSender)
    }

    // MARK: - HasPartsWithFilenames

    func testHasPartsWithFilenames() throws {
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
        XCTAssertTrue(msg.hasPartsWithFilenames)
        XCTAssertEqual(msg.attachmentParts.count, 1)
        XCTAssertEqual(msg.attachmentParts.first?.filename, "report.pdf")
    }

    // MARK: - GmailHistoryListResponse

    func testDecodeHistoryListResponse() throws {
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
        XCTAssertEqual(response.historyId, "99999")
        XCTAssertEqual(response.nextPageToken, "hist_token")
        XCTAssertEqual(response.history?.count, 1)

        let record = try XCTUnwrap(response.history?.first)
        XCTAssertEqual(record.id, "12345")
        XCTAssertEqual(record.messagesAdded?.count, 1)
        XCTAssertEqual(record.messagesAdded?.first?.message.id, "msg_new")
        XCTAssertEqual(record.labelsAdded?.count, 1)
        XCTAssertEqual(record.labelsAdded?.first?.labelIds, ["STARRED"])
        XCTAssertEqual(record.labelsRemoved?.count, 1)
        XCTAssertEqual(record.labelsRemoved?.first?.labelIds, ["UNREAD"])
    }

    // MARK: - GmailLabel

    func testDecodeGmailLabel() throws {
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
        XCTAssertEqual(label.id, "Label_42")
        XCTAssertEqual(label.name, "work/projects")
        XCTAssertEqual(label.displayName, "projects")
        XCTAssertEqual(label.type, "user")
        XCTAssertEqual(label.messagesTotal, 150)
        XCTAssertEqual(label.messagesUnread, 3)
        XCTAssertEqual(label.color?.backgroundColor, "#0000ff")
    }

    func testGmailLabelIsSystemLabel() throws {
        let inbox = GmailLabel(id: "INBOX", name: "INBOX", type: "system",
                               messagesTotal: nil, messagesUnread: nil,
                               threadsTotal: nil, threadsUnread: nil, color: nil)
        XCTAssertTrue(inbox.isSystemLabel)

        let custom = GmailLabel(id: "Label_1", name: "MyLabel", type: "user",
                                messagesTotal: nil, messagesUnread: nil,
                                threadsTotal: nil, threadsUnread: nil, color: nil)
        XCTAssertFalse(custom.isSystemLabel)
    }

    func testGmailLabelDisplayNameNoSlash() throws {
        let label = GmailLabel(id: "L1", name: "SimpleLabel", type: nil,
                               messagesTotal: nil, messagesUnread: nil,
                               threadsTotal: nil, threadsUnread: nil, color: nil)
        XCTAssertEqual(label.displayName, "SimpleLabel")
    }

    func testGmailLabelResolvedColors() throws {
        let withColor = GmailLabel(
            id: "L1", name: "Colored",
            type: nil, messagesTotal: nil, messagesUnread: nil,
            threadsTotal: nil, threadsUnread: nil,
            color: GmailLabelColor(textColor: "#ff0000", backgroundColor: "#00ff00")
        )
        XCTAssertEqual(withColor.resolvedBgColor, "#00ff00")
        XCTAssertEqual(withColor.resolvedTextColor, "#ff0000")

        let withoutColor = GmailLabel(id: "L2", name: "NoColor", type: nil,
                                      messagesTotal: nil, messagesUnread: nil,
                                      threadsTotal: nil, threadsUnread: nil, color: nil)
        // Should fall back to palette - just verify it returns a non-empty string
        XCTAssertFalse(withoutColor.resolvedBgColor.isEmpty)
        XCTAssertFalse(withoutColor.resolvedTextColor.isEmpty)
        XCTAssertTrue(withoutColor.resolvedBgColor.hasPrefix("#"))
    }

    // MARK: - GmailProfile

    func testDecodeGmailProfile() throws {
        let json = """
        {
            "emailAddress": "user@gmail.com",
            "messagesTotal": 12345,
            "threadsTotal": 6789,
            "historyId": "55555"
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(GmailProfile.self, from: json)
        XCTAssertEqual(profile.emailAddress, "user@gmail.com")
        XCTAssertEqual(profile.messagesTotal, 12345)
        XCTAssertEqual(profile.threadsTotal, 6789)
        XCTAssertEqual(profile.historyId, "55555")
    }

    // MARK: - GmailThread

    func testDecodeGmailThread() throws {
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
        XCTAssertEqual(thread.id, "thread_001")
        XCTAssertEqual(thread.historyId, "777")
        XCTAssertEqual(thread.messages?.count, 2)
    }

    // MARK: - GmailDraft

    func testDecodeGmailDraftListResponse() throws {
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
        XCTAssertEqual(response.drafts?.count, 2)
        XCTAssertEqual(response.drafts?[0].id, "d1")
        XCTAssertEqual(response.drafts?[0].message?.id, "m1")
        XCTAssertNil(response.drafts?[1].message)
    }

    // MARK: - Helpers

    /// Creates a GmailMessage with the specified headers, using JSON decoding.
    private func makeMessage(
        headers: [(String, String)],
        labelIds: [String]? = nil,
        htmlBodyData: String? = nil,
        plainBodyData: String? = nil
    ) -> GmailMessage {
        var headersJSON = headers.map { """
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
