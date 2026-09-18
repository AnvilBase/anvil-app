import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// What the window keeps clear for the notch and the home indicator.
///
/// A view that ignores the safe area hands everything inside it a safe area of nothing. That is the
/// point — it is what lets the chat run to the screen's edges with no strip of another colour left
/// behind the notch — but anything in there that must stay clear of the notch then has nothing to
/// go on. ``SidebarContainer`` ignores it for the whole screen, so both halves of the drawer ask
/// the window instead, which still knows.
enum WindowInsets {
  #if canImport(UIKit)
    private static var window: UIWindow? {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }
    }
  #endif

  /// The window's size, for a view that has to draw before it has been measured.
  static var windowSize: CGSize {
    #if canImport(UIKit)
      if let window { return window.bounds.size }
      return UIScreen.main.bounds.size
    #else
      return CGSize(width: 390, height: 844)
    #endif
  }

  static var current: EdgeInsets {
    #if canImport(UIKit)
      if let safeArea = window?.safeAreaInsets {
        return EdgeInsets(
          top: safeArea.top, leading: safeArea.left, bottom: safeArea.bottom,
          trailing: safeArea.right)
      }
    #endif
    return EdgeInsets()
  }

  /// How much of the window's safe area a view is not already being given.
  ///
  /// Not simply the window's own insets, because some of them do still arrive: the keyboard's is
  /// deliberately left alone so the composer rides up on it, and adding the home indicator on top
  /// of that would leave a gap between the two. This is the shortfall and nothing more — the whole
  /// inset where it went missing, nought where it survived.
  static func missing(from ambient: EdgeInsets) -> EdgeInsets {
    let window = current
    return EdgeInsets(
      top: max(window.top - ambient.top, 0),
      leading: max(window.leading - ambient.leading, 0),
      bottom: max(window.bottom - ambient.bottom, 0),
      trailing: max(window.trailing - ambient.trailing, 0))
  }
}
