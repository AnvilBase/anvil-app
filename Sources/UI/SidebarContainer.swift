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

  /// The insets to keep the drawer clear of the notch and the home indicator.
  ///
  /// A `GeometryReader` that ignores the safe area is not promised to keep reporting what it
  /// ignored, and on the reading where it reports nothing the drawer would sit under the notch. So
  /// the proxy is believed when it says something, and the window is asked when it doesn't.
  private static func resolvedInsets(_ proxy: EdgeInsets) -> EdgeInsets {
    if proxy.top > 0 { return proxy }
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

  /// The corner the chat is cut to: the screen's own, so that closed it sits exactly inside the
  /// display's rounding and open it carries that same curve into the middle of the screen.
  ///
  /// iOS 26 will work the radius out from the container for us, which is the only way to get it
  /// right on every device without reading a private property off `UIScreen`. Older releases get
  /// the radius the iPhones that run them are cut to, which is 55pt from the X on and a little
  /// less before that — near enough that no corner shows a seam.
  private static var pageShape: AnyShape {
    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        return AnyShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(34))))
      }
    #endif
    return AnyShape(RoundedRectangle(cornerRadius: 55, style: .continuous))
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
      let shape = Self.pageShape

      ZStack(alignment: .leading) {
        sidebar
          // A fallback keeps the drawer off the very edge on a device that reports no insets.
          .padding(.top, max(insets.top, 12))
          .padding(.bottom, max(insets.bottom, 12))
          .frame(width: width)
          .frame(maxHeight: .infinity)
          .accessibilityHidden(progress < 0.5)
          // The drawer keeps its full height if the keyboard is up behind the chat.
          .ignoresSafeArea(.keyboard)

        // The shadow is cast by a plain shape behind the chat, not by the chat itself. Shadowing
        // the conversation means rendering the whole screen off-screen again on every frame of the
        // drag, and on a long chat that is what made the drawer stutter.
        shape
          .fill(ChatStyle.page)
          .frame(width: proxy.size.width, height: proxy.size.height)
          .shadow(color: .black.opacity(0.28 * progress), radius: 22, x: -8)
          .offset(x: offset)
          .allowsHitTesting(false)

        content
          .frame(width: proxy.size.width, height: proxy.size.height)
          .overlay {
            // Dims the chat and takes the taps while the drawer is open. Under the clip, not over
            // it: a full square of black laid on top would paint its own corners straight back
            // over the rounded ones, and the chat would slide open looking square.
            Color.black
              .opacity(0.2 * progress)
              .allowsHitTesting(progress > 0.01)
              .onTapGesture { setOpen(false) }
          }
          .clipShape(shape)
          .offset(x: offset)
          .accessibilityHidden(progress > 0.5)
      }
      // What the rounded corners cut away, and the strips above and below the drawer, open onto
      // this rather than onto the black of the window behind everything.
      .background(ChatStyle.sidebar.ignoresSafeArea())
      #if canImport(UIKit)
        // One recogniser does both directions. A zero-sized view is the only way to reach into the
        // view hierarchy from here; it takes no touches of its own.
        .background {
          DrawerPan(isOpen: isOpen, drawerWidth: width) { phase in
            switch phase {
            case .changed(let translation):
              drag = translation
            case .ended(let translation, let velocity):
              settle(width: width, translation: translation, velocity: velocity)
            }
          }
        }
      #endif
    }
    // The notch and the home indicator are the chat's business, not the container's, so it runs
    // edge to edge. The keyboard is deliberately not ignored: the chat has to keep that inset for
    // the composer to ride up with the keyboard, and to follow a finger dragging it back down.
    .ignoresSafeArea(.container)
  }

  /// Lands on the side the finger was heading for, and carries on at the speed it left at: a flick
  /// decides on its own however little ground it covered, a slow drag by where it let go.
  private func settle(width: CGFloat, translation: CGFloat, velocity: CGFloat) {
    let travelled = (isOpen ? width : 0) + translation
    let shouldOpen = abs(velocity) > 250 ? velocity > 0 : travelled > width / 2
    let remaining = (shouldOpen ? width : 0) - travelled

    // Both in the same animation, and this is not a nicety. `drag` and `isOpen` are two halves of
    // one number: clearing the drag on its own puts the chat back where `isOpen` still has it —
    // wide open — and only then does the animation start, from there. That is the jump to the
    // right you see before a swipe-to-close plays out.
    withAnimation(Self.spring(velocity: velocity, remaining: remaining)) {
      drag = 0
      isOpen = shouldOpen
    }
  }

  private func setOpen(_ open: Bool) {
    withAnimation(ChatStyle.sidebarMotion) { isOpen = open }
  }

  /// The drawer's spring, told how fast the chat is already moving, so it keeps that pace instead
  /// of stopping dead and starting again. `initialVelocity` is measured in the distance still to
  /// cover per second, and capped: a hard flick with a few points left works out to a number that
  /// would fling the chat past its stop and back.
  private static func spring(velocity: CGFloat, remaining: CGFloat) -> Animation {
    guard abs(remaining) > 1 else { return ChatStyle.sidebarMotion }
    let initial = min(max(Double(velocity / remaining), -8), 24)
    return .interpolatingSpring(duration: 0.34, bounce: 0.08, initialVelocity: initial)
  }
}

#if canImport(UIKit)

  /// The drawer's gesture, as one UIKit pan on the screen behind the chat.
  ///
  /// SwiftUI's own `DragGesture` has to be told where the screen edge is and then argue with the
  /// conversation's scroll view over every touch. UIKit settles that argument for a living: the
  /// pan says up front whether a touch is its business, and the scroll view waits to hear before
  /// it starts scrolling. Taps are never delayed, because only other pans are asked to wait.
  private struct DrawerPan: UIViewRepresentable {
    /// What the pan has to say, and everything the container needs to hear.
    enum Phase {
      case changed(CGFloat)
      case ended(CGFloat, CGFloat)
    }

    var isOpen: Bool
    var drawerWidth: CGFloat
    var report: (Phase) -> Void

    func makeUIView(context: Context) -> UIView {
      let view = UIView(frame: .zero)
      view.isUserInteractionEnabled = false
      context.coordinator.update(from: self)
      // There is no window to hang the pan on until this view has been put in one.
      context.coordinator.attach(from: view)
      return view
    }

    func updateUIView(_ view: UIView, context: Context) {
      context.coordinator.update(from: self)
      context.coordinator.attach(from: view)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.detach() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
      private var isOpen = false
      private var report: (Phase) -> Void = { _ in }
      private(set) var pan: UIPanGestureRecognizer?

      func update(from view: DrawerPan) {
        isOpen = view.isOpen
        report = view.report
      }

      /// Hangs the pan on the screen as soon as there is one to hang it on, asking again on the
      /// next run loop for as long as it takes. A view is made before it is put in a window, and a
      /// recogniser attached to whatever happened to be its superview at that moment goes quietly
      /// dead the first time SwiftUI rebuilds around it.
      func attach(from view: UIView, attempt: Int = 0) {
        guard pan == nil else { return }
        guard let host = view.window?.rootViewController?.view else {
          guard attempt < 40 else { return }
          DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            self.attach(from: view, attempt: attempt + 1)
          }
          return
        }
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle))
        recognizer.delegate = self
        recognizer.maximumNumberOfTouches = 1
        host.addGestureRecognizer(recognizer)
        pan = recognizer
      }

      func detach() {
        if let pan { pan.view?.removeGestureRecognizer(pan) }
        pan = nil
      }

      @objc private func handle(_ gesture: UIPanGestureRecognizer) {
        guard let host = gesture.view else { return }
        let translation = gesture.translation(in: host).x
        switch gesture.state {
        case .began:
          // Out of the way before the chat starts moving, rather than halfway through the slide.
          host.endEditing(true)
        case .changed:
          report(.changed(translation))
        case .ended, .cancelled, .failed:
          // Cancelled counts: the drawer has to land somewhere either way.
          report(.ended(translation, gesture.velocity(in: host).x))
        default:
          break
        }
      }

      /// Whether this touch is the drawer's business at all: is it going sideways rather than down
      /// the page, and is it going the way the drawer can move?
      ///
      /// Pulling the drawer out is a rightward swipe anywhere on the chat — not a swipe that has to
      /// find a strip at the very edge of the screen, which is a thing you have to know about and
      /// then aim for. Pushing it back is a leftward swipe on the chat, which while the drawer is
      /// open means the part of the screen right of it: a swipe that starts on the drawer belongs
      /// to the drawer, whose list still scrolls and whose rows still swipe to delete.
      ///
      /// Everything else is somebody else's, and saying so here is what keeps the conversation
      /// scrolling normally.
      func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, let host = pan.view else { return false }
        let velocity = pan.velocity(in: host)
        // Decisively sideways: a diagonal that is mostly down the page is the conversation being
        // scrolled, and the drawer should stay out of it.
        guard abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
        guard isOpen else { return velocity.x > 0 }
        // Where the finger went down, not where it is now. A pan is only asked this once it has
        // already moved ten points or so, by which time the current position has wandered.
        let start = pan.location(in: host).x - pan.translation(in: host).x
        return velocity.x < 0 && start >= drawerEdge(in: host)
      }

      /// Scrolling waits to hear whether this is a drawer swipe; tapping never does.
      func gestureRecognizer(
        _: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
      ) -> Bool {
        other is UIPanGestureRecognizer
      }

      /// While the drawer is open the chat begins where the drawer ends, and a swipe that starts on
      /// the drawer belongs to the drawer — its list still scrolls, its rows still swipe to delete.
      private func drawerEdge(in host: UIView) -> CGFloat {
        min(ChatStyle.sidebarWidth, host.bounds.width * 0.86)
      }

      /// Two recognisers can both want a touch; this one is happy to share rather than be shut out
      /// by whichever asked first.
      func gestureRecognizer(
        _: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
      ) -> Bool { true }
    }
  }

#endif
