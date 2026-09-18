import Foundation
import Network
import Observation

/// Watches whether the phone has an internet connection, so web search can be turned off while
/// offline instead of failing. NWPathMonitor only reads the system's network state; it sends nothing.
@MainActor
@Observable
final class NetworkStatus {
  private(set) var isOnline = true

  /// Whether the way out is this phone's own cellular. A several-gigabyte download doesn't start on
  /// it unasked — and doesn't fail either, it waits for Wi-Fi, which is why the model screen says
  /// so rather than leaving a bar that never moves.
  private(set) var isCellular = false

  private let monitor = NWPathMonitor()

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let online = path.status == .satisfied
      let cellular = path.usesInterfaceType(.cellular)
      Task { @MainActor in
        self?.isOnline = online
        self?.isCellular = cellular
      }
    }
    monitor.start(queue: DispatchQueue(label: "\(AppFlavor.storageNamespace).NetworkStatus"))
  }
}
