import Foundation

/// Paces Gmail API calls to stay within the per-user quota limit.
/// Uses a sliding window over the last 60 seconds to track per-minute spend,
/// and a 1-second window to enforce per-second burst protection.
actor QuotaTracker {
    private let budgetPerMinute: Int
    private let budgetPerSecond: Int
    private var ledger: [(timestamp: Date, units: Int)] = []

    init(budgetPerMinute: Int = 15_000, budgetPerSecond: Int = 200) {
        self.budgetPerMinute = budgetPerMinute
        self.budgetPerSecond = budgetPerSecond
    }

    /// Current spend in the last 60 seconds.
    private var currentSpend: Int {
        prune()
        return ledger.reduce(0) { $0 + $1.units }
    }

    /// Remaining budget in the current minute window.
    var remainingBudget: Int {
        max(0, budgetPerMinute - currentSpend)
    }

    /// Returns true if spending `units` would stay within both per-minute and per-second budgets.
    func canSpend(_ units: Int) -> Bool {
        currentSpend + units <= budgetPerMinute && canSpendPerSecond(units)
    }

    /// Returns true if spending `units` would stay within the per-second burst limit.
    private func canSpendPerSecond(_ units: Int) -> Bool {
        let cutoff = Date().addingTimeInterval(-1)
        let recentSpend = ledger
            .filter { $0.timestamp >= cutoff }
            .reduce(0) { $0 + $1.units }
        return recentSpend + units <= budgetPerSecond
    }

    /// Records a spend of `units` at the current time.
    /// Skips recording if the calling task has been cancelled to prevent over-counting quota.
    func spend(_ units: Int) {
        guard !Task.isCancelled else { return }
        ledger.append((timestamp: Date(), units: units))
    }

    /// Test helper: record spend at a specific date.
    func spendAt(units: Int, date: Date) {
        ledger.append((timestamp: date, units: units))
    }

    /// Suspends until enough budget is available, then spends it.
    func waitForBudget(_ units: Int) async {
        precondition(units <= budgetPerMinute, "Requested \(units) exceeds budget \(budgetPerMinute)")
        while !canSpend(units) {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
        spend(units)
    }

    /// Removes entries older than 60 seconds.
    @discardableResult
    private func prune() -> Int {
        let cutoff = Date().addingTimeInterval(-60)
        let before = ledger.count
        ledger.removeAll { $0.timestamp < cutoff }
        return before - ledger.count
    }
}
