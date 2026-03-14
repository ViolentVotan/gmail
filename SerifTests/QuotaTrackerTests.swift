import Testing
@testable import Serif

@Suite struct QuotaTrackerTests {
    @Test func canSpendWithinBudget() async {
        let tracker = QuotaTracker(budgetPerMinute: 1000)
        let result = await tracker.canSpend(500)
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

    @Test func spendRecordsUnits() async {
        let tracker = QuotaTracker(budgetPerMinute: 100)
        await tracker.spend(50)
        await tracker.spend(30)
        let remaining = await tracker.remainingBudget
        #expect(remaining == 20)
    }
}
