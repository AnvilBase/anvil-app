import Foundation
import LocalAuthentication
import Observation

/// Locks the app behind Face ID, Touch ID, or the iPhone's passcode.
///
/// `deviceOwnerAuthentication` is the policy: Face ID where there is a face enrolled, and the
/// passcode where there isn't or when Face ID gives up — which is what "Face ID or passcode" means
/// on iOS, and why there is one switch and not two. Nothing about the face or the passcode reaches
/// the app; the system says yes or no.
///
/// The app locks when it leaves the screen and asks to unlock as soon as it is back. There is no
/// grace period: a lock that waits a minute is a lock that is off for a minute, and anyone who
/// turns this on has asked for the opposite.
@MainActor
@Observable
final class AppLock {
  private(set) var isLocked = false
  private(set) var isAuthenticating = false

  /// What stands in the way of unlocking, when something does: no passcode set, say.
  private(set) var problem: String?

  static var isAvailable: Bool {
    LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
  }

  func lock() {
    isLocked = true
    problem = nil
  }

  func unlock() async {
    guard isLocked, !isAuthenticating else { return }
    isAuthenticating = true
    defer { isAuthenticating = false }
    let context = LAContext()
    context.localizedCancelTitle = "Not now"
    var unavailable: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
      problem = unavailable?.localizedDescription ?? "Face ID and passcode aren't available."
      return
    }
    do {
      let ok = try await context.evaluatePolicy(
        .deviceOwnerAuthentication, localizedReason: "Unlock Anvil")
      if ok {
        isLocked = false
        problem = nil
      }
    } catch let error as LAError where error.code == .userCancel || error.code == .appCancel {
      // Cancelled is not a problem, it is a choice; the screen stays locked and offers again.
    } catch {
      problem = error.localizedDescription
    }
  }
}
