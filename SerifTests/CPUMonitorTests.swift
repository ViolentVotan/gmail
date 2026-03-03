import XCTest
@testable import Serif

final class CPUMonitorTests: XCTestCase {

    // MARK: - processCPUUsage

    func testProcessCPUUsage_returnsValidRange() {
        let monitor = CPUMonitor.shared
        let usage = monitor.processCPUUsage()
        // Process CPU can exceed 100 (multi-core) but should be non-negative
        XCTAssertGreaterThanOrEqual(usage, 0, "CPU usage should be >= 0")
    }

    func testProcessCPUUsage_afterDelayReturnsValidRange() {
        let monitor = CPUMonitor.shared
        _ = monitor.processCPUUsage() // prime cache
        // Wait beyond the 500ms cache interval to get a fresh sample
        Thread.sleep(forTimeInterval: 0.6)
        let usage = monitor.processCPUUsage()
        XCTAssertGreaterThanOrEqual(usage, 0, "CPU usage should be >= 0")
    }

    // MARK: - recommendedConcurrency

    func testRecommendedConcurrency_respectsMaxBound() {
        let monitor = CPUMonitor.shared
        let result = monitor.recommendedConcurrency(max: 5)
        XCTAssertGreaterThanOrEqual(result, 1)
        XCTAssertLessThanOrEqual(result, 5)
    }

    func testRecommendedConcurrency_atLeastOne() {
        let monitor = CPUMonitor.shared
        let result = monitor.recommendedConcurrency(max: 1)
        XCTAssertEqual(result, 1)
    }

    // MARK: - recommendedDelay

    func testRecommendedDelay_atLeastBase() {
        let monitor = CPUMonitor.shared
        let base: UInt64 = 200_000_000
        let delay = monitor.recommendedDelay(base: base)
        XCTAssertGreaterThanOrEqual(delay, base, "Delay should be at least the base value")
    }

    func testRecommendedDelay_atMost4xBase() {
        let monitor = CPUMonitor.shared
        let base: UInt64 = 200_000_000
        let delay = monitor.recommendedDelay(base: base)
        XCTAssertLessThanOrEqual(delay, base * 4, "Delay should be at most 4x the base value")
    }
}
