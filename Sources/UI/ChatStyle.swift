import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// The look the chat screens share: a plain page, a soft grey bubble for what you send, no bubble
/// at all for the reply, and Liquid Glass on the surfaces that float above the conversation.
enum ChatStyle {
  static let messageCorner: CGFloat = 20
  static let composerCorner: CGFloat = 24
  static let sidebarWidth: CGFloat = 320

  static let page = adaptive(light: .white, dark: Color(white: 0.078))
  static let userBubble = adaptive(light: Color(white: 0.945), dark: Color(white: 0.188))
  static let fieldFill = adaptive(light: Color(white: 0.949), dark: Color(white: 0.145))
  static let sidebar = adaptive(light: Color(white: 0.965), dark: Color(white: 0.11))
  static let sidebarRowHighlight = adaptive(light: Color(white: 0.886), dark: Color(white: 0.208))
  static let hairline = adaptive(light: Color(white: 0.886), dark: Color(white: 0.231))
  /// The filled circle Send sits in, and the colour of the arrow inside it.
  static let sendFill = adaptive(light: .black, dark: .white)
  static let sendGlyph = adaptive(light: .white, dark: .black)

  /// A colour that follows light and dark mode. Outside UIKit there's nothing to resolve it
  /// against, so the light value stands in.
  private static func adaptive(light: Color, dark: Color) -> Color {
    #if canImport(UIKit)
      Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    #else
      light
    #endif
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

  /// Fades the conversation out under the top bar instead of cutting it off, the way iOS 26 does
  /// with its own scroll edges.
  @ViewBuilder
  func softScrollEdges() -> some View {
    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        scrollEdgeEffectStyle(.soft, for: .all)
      } else {
        self
      }
    #else
      self
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
