import Testing
@testable import Vik
import Foundation

@Suite("PubSub Notification Parsing")
struct PubSubParsingTests {

    @Test("Decodes valid base64 notification payload")
    func decodeValidPayload() throws {
        let json = #"{"emailAddress":"user@example.com","historyId":"12345"}"#
        let base64 = Data(json.utf8).base64EncodedString()

        let message = PubSubMessage(data: base64, messageId: "msg1", publishTime: "2026-01-01T00:00:00Z")
        let data = Data(base64Encoded: message.data)!
        let notification = try JSONDecoder().decode(PubSubNotification.self, from: data)

        #expect(notification.emailAddress == "user@example.com")
        #expect(notification.historyId == "12345")
    }

    @Test("Handles invalid base64 gracefully")
    func invalidBase64() {
        let message = PubSubMessage(data: "not-valid-base64!!!", messageId: "msg2", publishTime: "2026-01-01T00:00:00Z")
        let data = Data(base64Encoded: message.data)
        #expect(data == nil)
    }

    @Test("Decodes PubSubPullResponse with no messages")
    func emptyPullResponse() throws {
        let json = #"{}"#
        let response = try JSONDecoder().decode(PubSubPullResponse.self, from: Data(json.utf8))
        #expect(response.receivedMessages == nil)
    }

    @Test("Decodes PubSubPullResponse with messages")
    func pullResponseWithMessages() throws {
        let notificationJSON = #"{"emailAddress":"test@test.com","historyId":"999"}"#
        let base64 = Data(notificationJSON.utf8).base64EncodedString()
        let json = """
        {
            "receivedMessages": [{
                "ackId": "ack123",
                "message": {
                    "data": "\(base64)",
                    "messageId": "mid1",
                    "publishTime": "2026-03-23T12:00:00Z"
                }
            }]
        }
        """
        let response = try JSONDecoder().decode(PubSubPullResponse.self, from: Data(json.utf8))
        #expect(response.receivedMessages?.count == 1)
        #expect(response.receivedMessages?.first?.ackId == "ack123")
    }
}

@Suite("GmailWatchResponse")
struct GmailWatchResponseTests {

    @Test("Decodes watch response with expiration")
    func decodeWatchResponse() throws {
        let json = #"{"historyId":"12345","expiration":"1711209600000"}"#
        let response = try JSONDecoder().decode(GmailWatchResponse.self, from: Data(json.utf8))
        #expect(response.historyId == "12345")
        #expect(response.expiration == "1711209600000")

        // Verify ms → Date conversion
        let date = Date(timeIntervalSince1970: Double(response.expiration)! / 1000.0)
        #expect(date > Date.distantPast)
    }
}

@Suite("PubSubConfig")
struct PubSubConfigTests {

    @Test("Config values are sensible")
    func configValues() {
        #expect(PubSubConfig.pullTimeout == 5.0)
        #expect(PubSubConfig.debounceInterval == 1.0)
        #expect(PubSubConfig.retryDelay == 2.0)
        #expect(PubSubConfig.backupPollingInterval == 300.0)
        #expect(PubSubConfig.watchRenewalInterval == 86_400)
        #expect(PubSubConfig.maxPullFailures == 3)
        #expect(PubSubConfig.subscriptionName.contains("gmail-notifications-sub"))
        #expect(PubSubConfig.topicName.contains("gmail-notifications"))
    }
}
