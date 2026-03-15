import Foundation
private import Network
import Observation

@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private(set) var isConnected = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.vikingz.serif.network-monitor"))
    }

    deinit {
        monitor.cancel()
    }
}
