import SwiftUI

#if canImport(UIKit)
  import UIKit

  /// Shows ``ProWelcome`` over everything, in a window of its own.
  ///
  /// An overlay on the root view sits under any sheet, and Pro is most often bought from the Pro
  /// page — which is pushed inside the Settings sheet, or presented as one from the chat. So the
  /// welcome played where nobody could see it. A window above them all always shows, and fading it
  /// away reveals whatever was underneath: the page they were on.
  @MainActor
  enum ProWelcomeWindow {
    private static var window: UIWindow?

    static func show() {
      guard window == nil else { return }
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
      else { return }

      let window = UIWindow(windowScene: scene)
      // Above the sheets, and above the alerts a sheet may have up.
      window.windowLevel = .alert + 1
      window.backgroundColor = .clear
      let host = UIHostingController(rootView: ProWelcome { dismiss() })
      host.view.backgroundColor = .clear
      window.rootViewController = host
      window.alpha = 0
      window.isHidden = false
      Self.window = window
      UIView.animate(withDuration: 0.45) { window.alpha = 1 }
    }

    private static func dismiss() {
      guard let window else { return }
      Self.window = nil
      UIView.animate(withDuration: 0.5) {
        window.alpha = 0
      } completion: { _ in
        window.isHidden = true
      }
    }
  }
#endif
