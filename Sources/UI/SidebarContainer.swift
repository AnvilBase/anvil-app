import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// The drawer the chat sits on top of. The chat slides to the right to uncover it, the same way it
/// works everywhere else on iOS: tap the button, swipe in from the left edge, or swipe the chat
/// back to put it away.
struct SidebarContainer<Sidebar: View, Content: View>: View {
  @Binding var isOpen: Bool
  @ViewBuilder var sidebar: Sidebar
  @ViewBuilder var content: Content

  /// How far the drag has moved the chat since it started, cleared when the drag ends.
  @State private var drag: CGFloat = 0

  private static var animation: Animation { .interpolatingSpring(duration: 0.34, bounce: 0.08) }

  /// The insets to keep the drawer clear of the notch and the home indicator.
  ///
  /// A `GeometryReader` that ignores the safe area is not promised to keep reporting what it
  /// ignored, and on the reading where it reports nothing the drawer would sit under the notch. So
  /// the proxy is believed when it says something, and the window is asked when it doesn't.
  private static func resolvedInsets(_ proxy: EdgeInsets) -> EdgeInsets {
    if proxy.top > 0 || proxy.bottom > 0 { return proxy }
    #if canImport(UIKit)
      let window = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }
      if let safeArea = window?.safeAreaInsets {
        return EdgeInsets(
          top: safeArea.top, leading: safeArea.left, bottom: safeArea.bottom,
          trailing: safeArea.right)
      }
    #endif
    return proxy
  }

  var body: some View {
    GeometryReader { proxy in
      // Ignoring the safe area means measuring the whole screen, so the chat runs edge to edge the
      // way every other iOS app does and no strip of a different colour is left behind the notch or
      // the home indicator. Each side then insets its own contents: the chat's NavigationStack does
      // it automatically, and the drawer is given the insets below.
      let insets = Self.resolvedInsets(proxy.safeAreaInsets)
      let width = min(ChatStyle.sidebarWidth, proxy.size.width * 0.86)
      let offset = min(max((isOpen ? width : 0) + drag, 0), width)
      let progress = width > 0 ? offset / width : 0

      ZStack(alignment: .leading) {
        sidebar
          // A fallback keeps the drawer off the very edge on a device that reports no insets.
          .padding(.top, max(insets.top, 12))
          .padding(.bottom, max(insets.bottom, 12))
          .frame(width: width)
          .frame(maxHeight: .infinity)
          // Slides in a little behind the chat rather than sitting still under it.
          .offset(x: -width * 0.22 * (1 - progress))
          .opacity(0.35 + 0.65 * progress)
          .accessibilityHidden(progress < 0.5)

        content
          .frame(width: proxy.size.width, height: proxy.size.height)
          .clipShape(RoundedRectangle(cornerRadius: 34 * progress, style: .continuous))
          .shadow(color: .black.opacity(0.28 * progress), radius: 22, x: -8)
          .overlay {
            // Dims the chat and takes the taps while the drawer is open.
            Color.black
              .opacity(0.2 * progress)
              .allowsHitTesting(progress > 0.01)
              .onTapGesture { setOpen(false) }
              .gesture(closeDrag(width: width))
          }
          .offset(x: offset)
          .accessibilityHidden(progress > 0.5)

        // The left edge of the chat, where a swipe opens the drawer.
        if !isOpen {
          Color.clear
            .frame(width: 18)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(openDrag(width: width))
        }
      }
      .background(ChatStyle.sidebar)
    }
    .ignoresSafeArea()
  }

  private func openDrag(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { drag = max(0, $0.translation.width) }
      .onEnded { value in
        finish(width: width, predicted: value.predictedEndTranslation.width, openedBefore: false)
      }
  }

  private func closeDrag(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { drag = min(0, $0.translation.width) }
      .onEnded { value in
        finish(width: width, predicted: value.predictedEndTranslation.width, openedBefore: true)
      }
  }

  /// Lands on whichever side the drag was heading for: past a third of the way, or thrown hard.
  private func finish(width: CGFloat, predicted: CGFloat, openedBefore: Bool) {
    let travelled = (openedBefore ? width : 0) + drag
    let shouldOpen = predicted > 60 || (predicted > -60 && travelled > width / 3)
    drag = 0
    setOpen(shouldOpen)
  }

  private func setOpen(_ open: Bool) {
    withAnimation(Self.animation) { isOpen = open }
  }
}
