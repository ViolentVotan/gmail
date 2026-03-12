import Testing
import Foundation
@testable import Serif

@Suite struct RetryDelayTests {

    @Test func firstRetryDelayIsOneSecond() {
        let delay = RetryPolicy.delay(forAttempt: 0)
        #expect(delay >= 1.0 && delay <= 1.5)
    }

    @Test func secondRetryDelayIsAboutTwoSeconds() {
        let delay = RetryPolicy.delay(forAttempt: 1)
        #expect(delay >= 2.0 && delay <= 3.0)
    }

    @Test func thirdRetryDelayIsAboutFourSeconds() {
        let delay = RetryPolicy.delay(forAttempt: 2)
        #expect(delay >= 4.0 && delay <= 6.0)
    }

    @Test func retriableStatusCodes() {
        #expect(RetryPolicy.isRetriable(statusCode: 429) == true)
        #expect(RetryPolicy.isRetriable(statusCode: 500) == true)
        #expect(RetryPolicy.isRetriable(statusCode: 503) == true)
        #expect(RetryPolicy.isRetriable(statusCode: 400) == false)
        #expect(RetryPolicy.isRetriable(statusCode: 404) == false)
        #expect(RetryPolicy.isRetriable(statusCode: 401) == false)
    }

    @Test func maxRetriesIsCapped() {
        #expect(RetryPolicy.maxRetries == 3)
    }

    @Test func retriableNetworkErrors() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(RetryPolicy.isRetriableNetworkError(timeout) == true)

        let connectionLost = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        #expect(RetryPolicy.isRetriableNetworkError(connectionLost) == true)

        let badURL = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)
        #expect(RetryPolicy.isRetriableNetworkError(badURL) == false)

        let nonURLError = NSError(domain: "com.custom", code: 1)
        #expect(RetryPolicy.isRetriableNetworkError(nonURLError) == false)
    }
}
