import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// The drawer the chat sits on top of. The chat slides to the right to uncover it, the same way it
/// works everywhere else on iOS: tap the button, swipe in from the left edge, or swipe the chat
/// back to put it away.
struct SidebarContainer<Sidebar: View, Content: View>: View {
  @Environment(\.theme) private var theme
  @Binding var isOpen: Bool
  @ViewBuilder var sidebar: Sidebar
  @ViewBuilder var content: Content

  /// How far the drag has moved the chat since it started, cleared when the drag ends.
  @State private var drag: CGFloat = 0
  /// How much of the screen the keyboard covers, measured from the keyboard itself: only
  /// whether it is up matters here. The container shrinks with the keyboard, so the drawer
  /// sits on it; the drawer's bottom padding clears the home indicator when there is no
  /// keyboard and just the keys when there is.
  @State private var keyboardHeight: CGFloat = 0

  /// The insets to keep the drawer clear of the notch and the home indicator.
  ///
  /// A view that ignores the safe area is not promised to keep being told what it ignored, and on
  /// the reading where it is told nothing the drawer would sit under the notch. So the measurement
  /// is believed when it says something, and the window is asked when it doesn't.
  private static func resolvedInsets(_ proxy: EdgeInsets) -> EdgeInsets {
    proxy.top > 0 ? proxy : WindowInsets.current
  }

  /// The screen as last measured — its size, and the safe area it was handed.
  @State private var measured = Measured(size: .zero, insets: EdgeInsets())

  private struct Measured: Equatable {
    var size: CGSize
    var insets: EdgeInsets
  }

  var body: some View {
    // The size comes from a measurement kept in state, not from a `GeometryReader` closure.
    // This used to be one, and the drawer stopped opening from its button: on iOS 26 the
    // closure is run again only when the geometry changes, and a read of `isOpen` made inside
    // it counts for nothing. The button set the state, this view's body ran, and the closure —
    // where the offset was worked out — did not, until the keyboard came up and changed the
    // layout. Everything here is worked out in the body itself, where a read is a dependency.
    let insets = Self.resolvedInsets(measured.insets)
    let keyboardUp = keyboardHeight > 0
    let size = measured.size == .zero ? WindowInsets.windowSize : measured.size
    let width = min(ChatStyle.sidebarWidth, size.width * 0.86)
    let offset = min(max((isOpen ? width : 0) + drag, 0), width)
    let progress = width > 0 ? offset / width : 0
    let shape = RoundedRectangle(cornerRadius: ChatStyle.pageCorner, style: .continuous)
    // The drawer is there the moment the chat starts moving rather than arriving with it, so
    // the first few points of a drag already show what is underneath.
    let revealed = min(1, progress * 1.5)

    ZStack(alignment: .leading) {
      sidebar
        // A fallback keeps the drawer off the very edge on a device that reports no insets. The
        // bottom clears the home indicator, or, with the keyboard up — when the measured inset
        // is the keyboard's height, not the indicator's — just the keys: the drawer shrinks
        // with the keyboard the way the chat does, so its search field comes to rest on it.
        .padding(.top, max(insets.top, 12))
        .padding(.bottom, keyboardUp ? 12 : max(WindowInsets.current.bottom, 12))
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // Closing, the drawer doesn't simply get covered over — it goes out of focus and fades,
        // hanging back a little as the chat comes across it, and all three follow the finger
        // rather than the clock. Opening, it runs in reverse and the drawer comes to meet you.
        .blur(radius: (1 - revealed) * 10)
        .opacity(revealed)
        .offset(x: -(1 - progress) * width * 0.22)
        .accessibilityHidden(progress < 0.5)

      // The shadow is cast by a plain shape behind the chat, not by the chat itself. Shadowing
      // the conversation means rendering the whole screen off-screen again on every frame of the
      // drag, and on a long chat that is what made the drawer stutter.
      shape
        .fill(theme.page)
        .frame(width: size.width)
        .frame(maxHeight: .infinity)
        .padding(.bottom, isOpen ? -keyboardHeight : 0)
        // Two soft ones rather than one dark one. A single 28% shadow at this size reads as a
        // grey band painted down the edge of the page — and it no longer has to carry the
        // separating on its own, now that the hairline draws the edge and the page lifts off the
        // drawer as it goes. So: a wide, faint one for the depth, and a short, fainter one just
        // under the edge for the contact, which together fall away instead of stopping.
        .shadow(color: .black.opacity(0.10 * progress), radius: 30, x: -10)
        .shadow(color: .black.opacity(0.06 * progress), radius: 8, x: -2)
        .offset(x: offset)
        .allowsHitTesting(false)

      content
        // The width is the measurement's, because the drawer's travel is worked out from it. The
        // height is whatever there is, which the keyboard takes its share of — how the composer
        // rides up when the keyboard is the chat's. With the drawer open the keyboard is the
        // drawer's search field's, and the chat behind must hold still: it is laid out taller by
        // the keyboard's height through a negative padding, which extends what is drawn without
        // extending what is reported, so nothing above overflows. (Ignoring the keyboard's safe
        // area or sizing the chat to the window both overflowed, and a view that overflows with
        // a focused field under the keys is shifted up wholesale by the system — the very
        // thing being fixed.)
        .frame(width: size.width)
        .frame(maxHeight: .infinity)
        .overlay {
          // The chat lifts off the drawer as it slides rather than being dimmed into it, a
          // shade at a time and in step with the finger. Under the clip, not over it: a full
          // square laid on top would paint its own corners straight back over the rounded ones,
          // and the chat would slide open looking square.
          ChatStyle.pageLift
            .opacity(0.1 * progress)
            .allowsHitTesting(progress > 0.01)
            .onTapGesture { setOpen(false) }
        }
        .clipShape(shape)
        .overlay {
          // The page and the drawer are the same colour, so this hairline is what actually draws
          // the edge of the chat. It arrives with the slide and is gone by the time the chat is
          // closed and its corners are back outside the screen.
          shape
            .strokeBorder(theme.hairline, lineWidth: 0.75)
            .opacity(progress)
            .allowsHitTesting(false)
        }
        // After the clip, so the clip runs the full taller height rather than cutting the page
        // off at the keyboard with a rounded corner just above the keys.
        .padding(.bottom, isOpen ? -keyboardHeight : 0)
        .offset(x: offset)
        .accessibilityHidden(progress > 0.5)
    }
    // Fills what it is given, the way the GeometryReader did, and measures it.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // What the rounded corners cut away, and the strips above and below the drawer, open onto
    // this rather than onto the black of the window behind everything.
    .background(theme.page.ignoresSafeArea())
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
    .onGeometryChange(for: Measured.self) { proxy in
      Measured(size: proxy.size, insets: proxy.safeAreaInsets)
    } action: { measured = $0 }
    // The notch and the home indicator are the chat's business, not the container's, so it runs
    // edge to edge. The keyboard is kept: the container shrinks with it, which is how the chat's
    // composer rides up when the keyboard is the chat's, and how the drawer's search field sits
    // on the keys when it is the drawer's — the chat behind the drawer is sized to the window
    // then, above, and holds still.
    .ignoresSafeArea(.container)
    #if canImport(UIKit)
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
        keyboardTo(note)
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
        withAnimation(.snappy(duration: 0.25)) { keyboardHeight = 0 }
      }
    #endif
  }

  #if canImport(UIKit)
    /// How far up the screen the keyboard now reaches, from its own frame.
    private func keyboardTo(_ note: Notification) {
      guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
      let keyboard = frame.cgRectValue
      let window = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
      let height = window?.bounds.height ?? UIScreen.main.bounds.height
      let covered = max(0, height - keyboard.minY)
      withAnimation(.snappy(duration: 0.25)) { keyboardHeight = covered }
    }
  #endif

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
    return .interpolatingSpring(duration: 0.26, bounce: 0.04, initialVelocity: initial)
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
