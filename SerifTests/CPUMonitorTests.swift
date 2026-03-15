import Testing
import Foundation
@testable import Serif

@Suite struct CPUMonitorTests {

    // MARK: - processCPUUsage

    @Test func processCPUUsage_returnsValidRange() {
        let monitor = CPUMonitor.shared
        let usage = monitor.processCPUUsage()
        // Process CPU can exceed 100 (multi-core) but should be non-negative
        #expect(usage >= 0, "CPU usage should be >= 0")
    }

    @Test func processCPUUsage_afterDelayReturnsValidRange() async throws {
        let monitor = CPUMonitor.shared
        _ = monitor.processCPUUsage() // prime cache
        // Wait beyond the 500ms cache interval to get a fresh sample
        try await Task.sleep(for: .milliseconds(600))
        let usage = monitor.processCPUUsage()
        #expect(usage >= 0, "CPU usage should be non-negative")
        // On a running process, usage should be finite (not NaN/Inf)
        #expect(usage.isFinite, "CPU usage should be a finite number")
    }

    // MARK: - recommendedConcurrency

    @Test func recommendedConcurrency_respectsMaxBound() {
        let monitor = CPUMonitor.shared
        let result = monitor.recommendedConcurrency(max: 5)
        #expect(result >= 1)
        #expect(result <= 5)
    }

    @Test func recommendedConcurrency_atLeastOne() {
        let monitor = CPUMonitor.shared
        let result = monitor.recommendedConcurrency(max: 1)
        #expect(result == 1)
    }

    // MARK: - recommendedDelay

    @Test func recommendedDelay_atLeastBase() {
        let monitor = CPUMonitor.shared
        let base: Duration = .milliseconds(200)
        let delay = monitor.recommendedDelay(base: base)
        #expect(delay >= base, "Delay should be at least the base value")
    }

    @Test func recommendedDelay_atMost4xBase() {
        let monitor = CPUMonitor.shared
        let base: Duration = .milliseconds(200)
        let delay = monitor.recommendedDelay(base: base)
        #expect(delay <= base * 4, "Delay should be at most 4x the base value")
    }
}
