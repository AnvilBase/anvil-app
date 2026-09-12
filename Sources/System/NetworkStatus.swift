import Foundation
import Network
import Observation

/// Watches whether the phone has an internet connection, so web search can be turned off while
/// offline instead of failing. NWPathMonitor only reads the system's network state; it sends nothing.
@MainActor
@Observable
final class NetworkStatus {
  private(set) var isOnline = true

  private let monitor = NWPathMonitor()

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let online = path.status == .satisfied
      Task { @MainActor in self?.isOnline = online }
    }
    monitor.start(queue: DispatchQueue(label: "\(AppFlavor.storageNamespace).NetworkStatus"))
  }
}
