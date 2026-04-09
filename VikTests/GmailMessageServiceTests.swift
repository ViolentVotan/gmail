import Foundation
import Testing
@testable import Vik

@Suite struct GmailMessageServiceTests {
    @Test func watchPayloadUsesLowercaseIncludeBehavior() throws {
        let payload = try GmailMessageService.watchRequestPayload(
            topicName: "projects/test/topics/gmail",
            labelIds: ["INBOX"]
        )
        let json = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])

        #expect(json["topicName"] as? String == "projects/test/topics/gmail")
        #expect(json["labelFilterBehavior"] as? String == "include")
    }

    @Test func batchDeleteQuotaUnitsAreFixedPerRequest() {
        #expect(GmailMessageService.batchDeleteQuotaUnits(forBatchSize: 0) == 0)
        #expect(GmailMessageService.batchDeleteQuotaUnits(forBatchSize: 1) == 50)
        #expect(GmailMessageService.batchDeleteQuotaUnits(forBatchSize: 1000) == 50)
    }
}
