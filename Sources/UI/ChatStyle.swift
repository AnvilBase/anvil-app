import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// The look the chat screens share: a plain page, a soft grey bubble for what you send, no bubble
/// at all for the reply, and Liquid Glass on the surfaces that float above the conversation.
enum ChatStyle {
  static let messageCorner: CGFloat = 22
  static let composerCorner: CGFloat = 30
  static let sidebarWidth: CGFloat = 320

  // MARK: - Controls
  //
  // Three sizes, and every round button in the app is one of them, so they stay in proportion to
  // each other and to the type when any of it moves. All three are comfortably past the 44pt
  // Apple asks for, because a phone held one-handed is not a mouse.

  /// Every round button that stands on its own: the bar across the top of the chat, the drawer's
  /// settings button and the row along its bottom, the photo viewer. One size, because they are
  /// the same kind of thing wherever you meet them.
  static let control: CGFloat = 60
  /// Buttons that sit inside a denser row rather than on their own — the composer's, and the
  /// jump-to-latest that floats just above it.
  static let inlineControl: CGFloat = 50
  /// The actions under a reply, a row of glyphs rather than a row of buttons.
  static let smallControl: CGFloat = 40
  static let controlGlyph: CGFloat = 24
  static let inlineControlGlyph: CGFloat = 22
  static let smallControlGlyph: CGFloat = 20
  /// The corner the chat is cut to once it starts sliding over the drawer. Rounder than the
  /// display's own, which is what makes it read as a card lifted off the screen rather than as the
  /// screen itself; nothing shows through the extra, because what is behind it is the same colour.
  static let pageCorner: CGFloat = 62
  /// The spring the drawer opens and closes with. Shared, so the button, the edge swipe and the
  /// swipe back all land the same way. Short and almost without bounce: the drawer should feel
  /// like it is being carried by the finger and then let go, not thrown.
  static let sidebarMotion: Animation = .interpolatingSpring(duration: 0.26, bounce: 0.04)
  /// Sending: the message lifting out of the capsule, the capsule collapsing back to one line, and
  /// the conversation scrolling up to meet it all ride the same spring, so they read as one motion.
  static let sendMotion: Animation = .spring(duration: 0.32, bounce: 0.12)
  /// The empty space kept under a reply while it is being written, on top of the usual room at the
  /// end of the conversation. About a line of it: the conversation follows the reply a line at a
  /// time and takes a moment to get there, and without a runway the sentence being written spends
  /// that moment down against the composer, in the fade, half gone. It closes when the reply does.
  static let replyRunway: CGFloat = 52
  /// The conversation keeping pace with a reply as it is written. Short, and without bounce: each
  /// step is retargeted by the next piece of text before it has finished, and anything springy
  /// would still be settling from the last word while the next one is being put down.
  static let followMotion: Animation = .smooth(duration: 0.22)
  /// A confirmation sliding up out of the button that asked for it, and back into it.
  static let confirmMotion: Animation = .snappy(duration: 0.25)

  // The colours — the page, the bubbles, the hairline, the one filled button — are a `Theme`, read
  // from the environment by every view that draws with them, so Anvil Pro's themes change the whole
  // app together. `AppTheme.ink` is the look these used to be.

  /// Laid over the chat as it slides, in step with how far it has gone, so the page lightens off
  /// the drawer behind it. White, so it only ever lifts: in the light theme the page is already
  /// white and stays put, and the hairline and the shadow do the separating instead.
  static let pageLift = Color.white

  /// A colour that follows light and dark mode. Outside UIKit there's nothing to resolve it
  /// against, so the light value stands in. `Theme` builds its palettes with this too.
  static func adaptive(light: Color, dark: Color) -> Color {
    #if canImport(UIKit)
      Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    #else
      light
    #endif
  }
}

extension AppearancePreference {
  /// What to hand `preferredColorScheme`. Nothing at all for `system`, which is how SwiftUI is told
  /// to keep following the phone.
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

// MARK: - Liquid Glass

/// Liquid Glass arrived with the iOS 26 SDK, so every call to it sits behind two gates: a compiler
/// check, because the project still builds with older Xcodes that have never heard of these APIs,
/// and an availability check, because the app still runs on the iOS 17 its deployment target
/// promises. Where neither holds, a material stands in — the same idea, one generation older.
extension View {
  /// A surface that floats over the conversation: the composer, the sidebar's search field, the
  /// jump-to-latest button.
  @ViewBuilder
  func liquidGlass(in shape: some Shape, interactive: Bool = false) -> some View {
    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        glassEffect(.regular.interactive(interactive), in: shape)
      } else {
        background(.regularMaterial, in: shape)
      }
    #else
      background(.regularMaterial, in: shape)
    #endif
  }

  /// Same, but tinted — used for the one control that is meant to stand out, Send.
  @ViewBuilder
  func liquidGlass(in shape: some Shape, tint: Color) -> some View {
    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        glassEffect(.regular.tint(tint).interactive(), in: shape)
      } else {
        background(tint, in: shape)
      }
    #else
      background(tint, in: shape)
    #endif
  }

}

/// Groups nearby glass surfaces so they bend light as one piece and flow into each other when they
/// move, rather than each being its own separate pane.
struct LiquidGlassGroup<Content: View>: View {
  var spacing: CGFloat = 16
  @ViewBuilder var content: Content

  var body: some View {
    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        GlassEffectContainer(spacing: spacing) { content }
      } else {
        content
      }
    #else
      content
    #endif
  }
}

extension View {
  /// Reports this view's width whenever it changes.
  func measuringWidth(_ report: @escaping (CGFloat) -> Void) -> some View {
    background {
      GeometryReader { proxy in
        Color.clear
          .onAppear { report(proxy.size.width) }
          .onChange(of: proxy.size.width) { _, width in report(width) }
      }
    }
  }

  /// Reports this view's height whenever it changes. Used to lay a message out off-screen and ask
  /// how tall it came out.
  func measuringHeight(_ report: @escaping (CGFloat) -> Void) -> some View {
    background {
      GeometryReader { proxy in
        Color.clear
          .onAppear { report(proxy.size.height) }
          .onChange(of: proxy.size.height) { _, height in report(height) }
      }
    }
  }
}

// MARK: - The fade at the ends of the conversation

extension ChatStyle {
  /// How far a line of the conversation takes to dissolve as it leaves the screen. Short: this is
  /// meant to be noticed only as the text having thinned out by the time it is gone, not as a band
  /// laid over the conversation.
  static let scrollFade: CGFloat = 40
}

extension View {
  /// Fades what is scrolling out of the conversation, at the top and at the bottom.
  ///
  /// Nothing over the chat is opaque — the bar is a few glass circles, the composer a glass
  /// capsule — and the conversation is not made to stop at either of them. It carries on past
  /// both, through the glass and out the other side, and gives itself up in the last
  /// ``ChatStyle/scrollFade`` points at the edge of the screen itself: in the notch above, and in
  /// the strip below the composer. Neither end finishes on a line.
  ///
  /// The mask is laid out from inside the safe area, because that is what it is given, and then
  /// hung off both insets so it covers the whole scroll view rather than the part of it left over
  /// between the two. The ends stay right whatever moves them: the notch, the keyboard, the
  /// composer growing a line or taking a photo.
  func scrollEdgeFade(_ length: CGFloat = ChatStyle.scrollFade) -> some View {
    mask {
      GeometryReader { proxy in
        let insets = proxy.safeAreaInsets
        VStack(spacing: 0) {
          fadeBand(height: min(insets.top, length), towards: .top)
          Color.black
          fadeBand(height: min(insets.bottom, length), towards: .bottom)
        }
        .frame(height: proxy.size.height + insets.top + insets.bottom)
        .offset(y: -insets.top)
      }
    }
  }

  /// One end of the fade: opaque where the conversation is read, clear where it runs out.
  private func fadeBand(height: CGFloat, towards edge: VerticalEdge) -> some View {
    LinearGradient(
      // Eased rather than a straight ramp — a linear fade reads as the text dimming evenly, and
      // what is wanted is for it to hold its colour and then go.
      stops: [
        .init(color: .black.opacity(0), location: 0),
        .init(color: .black.opacity(0.15), location: 0.34),
        .init(color: .black.opacity(0.58), location: 0.68),
        .init(color: .black, location: 1),
      ],
      startPoint: edge == .top ? .top : .bottom,
      endPoint: edge == .top ? .bottom : .top
    )
    .frame(height: height)
  }
}
