import Foundation

/// Paces Gmail API calls to stay within the per-user quota limit.
/// Uses a sliding window over the last 60 seconds to track per-minute spend.
///
/// Quota costs per method (from https://developers.google.com/workspace/gmail/api/reference/quota):
///   messages.get/list: 5    history.list: 2    labels.list/get: 1
///   messages.send: 100      messages.batchDelete: 50
///   messages.modify: 5      watch: 100          getProfile: 1
///   drafts.get/list: 5      threads.get/list: 10
///
/// Limits (official, no per-second limit exists):
///   Per-user:    15,000 quota units per minute
///   Per-project: 1,200,000 quota units per minute
///
/// Concurrent requests are throttled server-side (HTTP 429 "Too many concurrent
/// requests for user") — handled by retry logic in GmailAPIClient, not here.
actor QuotaTracker {
    static let shared = QuotaTracker()

    private let budgetPerMinute: Int
    private var ledger: [(timestamp: Date, units: Int)] = []
    private var _cachedSpend: Int = 0

    init(budgetPerMinute: Int = 15_000) {
        self.budgetPerMinute = budgetPerMinute
    }

    /// Current spend in the last 60 seconds (cached, updated lazily on prune/record).
    private var currentSpend: Int {
        pruneIfNeeded()
        return _cachedSpend
    }

    /// Remaining budget in the current minute window.
    var remainingBudget: Int {
        max(0, budgetPerMinute - currentSpend)
    }

    /// Returns true if spending `units` would stay within the per-minute budget.
    func canSpend(_ units: Int) -> Bool {
        currentSpend + units <= budgetPerMinute
    }

    /// Records a spend of `units` at the current time.
    /// Skips recording if the calling task has been cancelled to prevent over-counting quota.
    func spend(_ units: Int) {
        guard !Task.isCancelled else { return }
        ledger.append((timestamp: Date(), units: units))
        _cachedSpend += units
    }

    /// Test helper: record spend at a specific date.
    func spendAt(units: Int, date: Date) {
        ledger.append((timestamp: date, units: units))
        _cachedSpend += units
    }

    /// Suspends until enough budget is available, then spends it.
    func waitForBudget(_ units: Int) async {
        precondition(units <= budgetPerMinute, "Requested \(units) exceeds budget \(budgetPerMinute)")
        while !canSpend(units) {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
        spend(units)
    }

    /// Removes entries older than 60 seconds, subtracting their units from the cached spend.
    private func pruneIfNeeded() {
        let cutoff = Date().addingTimeInterval(-60)
        guard let oldest = ledger.first, oldest.timestamp < cutoff else { return }
        var removed = 0
        ledger.removeAll { entry in
            guard entry.timestamp < cutoff else { return false }
            removed += entry.units
            return true
        }
        _cachedSpend -= removed
    }
}
