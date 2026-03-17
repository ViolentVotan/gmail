import Foundation
private import Network
import Observation
import Synchronization

@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private(set) var isConnected = true
    private let monitor = NWPathMonitor()

    /// Thread-safe read for non-MainActor contexts (avoids MainActor hop on API hot path).
    /// Static so callers use `NetworkMonitor.isReachable` without needing the @MainActor `shared` instance.
    nonisolated static let reachable = Mutex(true)
    nonisolated static var isReachable: Bool { reachable.withLock { $0 } }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Self.reachable.withLock { $0 = connected }
            Task { @MainActor [weak self] in
                self?.isConnected = connected
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.vikingz.vik.network-monitor"))
    }

    deinit {
        monitor.cancel()
    }
}
