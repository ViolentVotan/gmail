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
    static let shared = QuotaTracker(interactiveReserve: 3_000)

    private let budgetPerMinute: Int

    /// Units reserved for interactive user actions (star, archive, send, label
    /// modify) that bypass quota tracking. Sync never consumes more than
    /// `budgetPerMinute - interactiveReserve`, leaving headroom so a burst of
    /// user actions + running sync won't exceed the 15k/min per-user limit.
    private let interactiveReserve: Int

    private var ledger: [(timestamp: Date, units: Int)] = []
    private var ledgerStartIndex = 0
    private var _cachedSpend: Int = 0

    init(budgetPerMinute: Int = 15_000, interactiveReserve: Int = 0) {
        self.budgetPerMinute = budgetPerMinute
        self.interactiveReserve = interactiveReserve
    }

    /// Current spend in the last 60 seconds (cached, updated lazily on prune/record).
    private var currentSpend: Int {
        pruneIfNeeded()
        return _cachedSpend
    }

    /// Remaining sync budget in the current minute window (accounts for interactive reserve).
    var remainingBudget: Int {
        max(0, budgetPerMinute - interactiveReserve - currentSpend)
    }

    /// Returns true if spending `units` would stay within the effective sync budget
    /// (per-minute budget minus the interactive reserve).
    func canSpend(_ units: Int) -> Bool {
        currentSpend + units <= budgetPerMinute - interactiveReserve
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
        guard units <= budgetPerMinute else {
            assertionFailure("Requested \(units) exceeds budget \(budgetPerMinute)")
            return
        }
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
        guard ledgerStartIndex < ledger.count, ledger[ledgerStartIndex].timestamp < cutoff else { return }
        while ledgerStartIndex < ledger.count, ledger[ledgerStartIndex].timestamp < cutoff {
            _cachedSpend -= ledger[ledgerStartIndex].units
            ledgerStartIndex += 1
        }
        if ledgerStartIndex > 64, ledgerStartIndex * 2 >= ledger.count {
            ledger.removeFirst(ledgerStartIndex)
            ledgerStartIndex = 0
        }
    }
}
