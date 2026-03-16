import Testing
import Foundation
@testable import Serif

@Suite struct QuotaTrackerTests {
    @Test func canSpendWithinBudget() async {
        let tracker = QuotaTracker(budgetPerMinute: 1000)
        let result = await tracker.canSpend(500)
        #expect(result == true)
    }

    @Test func canSpendLargeAmountWithinBudget() async {
        // Verify large requests (like batch fetches of 500 messages × 5 units)
        // succeed when budget is available — this was previously blocked by a
        // fake per-second limit that caused an infinite loop.
        let tracker = QuotaTracker(budgetPerMinute: 15_000)
        let result = await tracker.canSpend(2500)
        #expect(result == true)
    }

    @Test func cannotExceedBudget() async {
        let tracker = QuotaTracker(budgetPerMinute: 100)
        await tracker.spend(90)
        let result = await tracker.canSpend(20)
        #expect(result == false)
    }

    @Test func budgetResetsAfterOneMinute() async {
        let tracker = QuotaTracker(budgetPerMinute: 100)
        // Inject old entries that should be pruned
        await tracker.spendAt(units: 90, date: Date().addingTimeInterval(-61))
        let result = await tracker.canSpend(90)
        #expect(result == true)
    }

    @Test func waitForBudgetCompletesForLargeAmount() async {
        // Regression: waitForBudget(2500) previously infinite-looped due to a
        // fake per-second limit (200 units/sec). Gmail API has no per-second quota.
        let tracker = QuotaTracker(budgetPerMinute: 15_000)
        await tracker.waitForBudget(2500)
        let remaining = await tracker.remainingBudget
        #expect(remaining == 12_500)
    }

    @Test func spendRecordsUnits() async {
        let tracker = QuotaTracker(budgetPerMinute: 100)
        await tracker.spend(50)
        await tracker.spend(30)
        let remaining = await tracker.remainingBudget
        #expect(remaining == 20)
    }
}
