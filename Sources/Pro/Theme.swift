import SwiftUI

/// The look of the app, as a set of colours the chat is drawn with.
///
/// Ink is what the app has always looked like and what everyone gets. The rest are Anvil Pro: the
/// same page and the same bubbles with the light turned, and the one filled button — Send,
/// Continue, Download — in a colour instead of in ink. Nothing else changes, because nothing else
/// should: a theme is a mood, not a redesign.
enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
  case ink
  case ember
  case frost
  case moss
  case rose

  var id: Self { self }

  var label: String {
    switch self {
    case .ink: "Ink"
    case .ember: "Ember"
    case .frost: "Frost"
    case .moss: "Moss"
    case .rose: "Rose"
    }
  }

  /// The one theme that isn't Pro.
  var isFree: Bool { self == .ink }

  /// The colour that stands for the theme: on the picker's swatch, and on the filled button.
  var swatch: Color { palette.sendFill }

  var palette: Theme {
    switch self {
    case .ink:
      Theme(
        page: ChatStyle.adaptive(light: .white, dark: Color(white: 0.078)),
        userBubble: ChatStyle.adaptive(light: Color(white: 0.945), dark: Color(white: 0.188)),
        fieldFill: ChatStyle.adaptive(light: Color(white: 0.949), dark: Color(white: 0.145)),
        sidebarRowHighlight: ChatStyle.adaptive(
          light: Color(white: 0.886), dark: Color(white: 0.208)),
        hairline: ChatStyle.adaptive(light: Color(white: 0.886), dark: Color(white: 0.231)),
        sendFill: ChatStyle.adaptive(light: .black, dark: .white),
        sendGlyph: ChatStyle.adaptive(light: .white, dark: .black),
        accent: ChatStyle.adaptive(light: .black, dark: .white),
        mark: .secondary)
    case .ember:
      Self.tinted(
        hue: Color(red: 1.0, green: 0.47, blue: 0.16), light: (0.98, 0.965, 0.95),
        dark: (0.10, 0.075, 0.06))
    case .frost:
      Self.tinted(
        hue: Color(red: 0.36, green: 0.66, blue: 1.0), light: (0.955, 0.97, 0.99),
        dark: (0.06, 0.08, 0.11))
    case .moss:
      Self.tinted(
        hue: Color(red: 0.32, green: 0.72, blue: 0.46), light: (0.955, 0.975, 0.96),
        dark: (0.06, 0.09, 0.07))
    case .rose:
      Self.tinted(
        hue: Color(red: 1.0, green: 0.42, blue: 0.62), light: (0.99, 0.96, 0.97),
        dark: (0.11, 0.065, 0.08))
    }
  }

  /// A page with a little of the hue in it, bubbles a step up from the page, and the button in the
  /// hue itself. The greys are built from the page so a theme is one decision, not eight.
  private static func tinted(
    hue: Color, light: (Double, Double, Double), dark: (Double, Double, Double)
  ) -> Theme {
    func lift(_ c: (Double, Double, Double), by amount: Double) -> Color {
      Color(red: c.0 + amount, green: c.1 + amount, blue: c.2 + amount)
    }
    return Theme(
      page: ChatStyle.adaptive(light: lift(light, by: 0), dark: lift(dark, by: 0)),
      userBubble: ChatStyle.adaptive(light: lift(light, by: -0.05), dark: lift(dark, by: 0.11)),
      fieldFill: ChatStyle.adaptive(light: lift(light, by: -0.045), dark: lift(dark, by: 0.07)),
      sidebarRowHighlight: ChatStyle.adaptive(
        light: lift(light, by: -0.1), dark: lift(dark, by: 0.13)),
      hairline: ChatStyle.adaptive(light: lift(light, by: -0.1), dark: lift(dark, by: 0.15)),
      sendFill: hue,
      sendGlyph: .white,
      accent: hue,
      mark: hue)
  }
}

/// The colours a theme resolves to. Read from the environment — `@Environment(\.theme)` — by every
/// view that draws the chat, so the whole app changes together when the theme does.
struct Theme: Equatable {
  let page: Color
  let userBubble: Color
  let fieldFill: Color
  let sidebarRowHighlight: Color
  let hairline: Color
  /// The filled circle Send sits in, and the colour of the arrow inside it.
  let sendFill: Color
  let sendGlyph: Color
  /// What controls are tinted with: links, pickers, toggles.
  let accent: Color
  /// The anvil on the empty page. Ink keeps it the grey of the guide under it; a coloured theme
  /// draws it in its own hue, so the theme is on the page from the first look.
  let mark: Color

  /// The drawer is not a different surface from the chat, it is the same one seen from further
  /// down. What tells them apart is the chat lifting off it as it slides — see `SidebarContainer` —
  /// not a change of colour.
  var sidebar: Color { page }
}

extension EnvironmentValues {
  @Entry var theme: Theme = AppTheme.ink.palette
}

/// Which icon sits on the Home Screen. `anvil` is the icon the app ships with; the rest are
/// alternates compiled from the asset catalog and switched with `setAlternateIconName`.
enum AppIconChoice: String, Codable, CaseIterable, Identifiable, Sendable {
  case anvil
  case pro
  case inverse
  case ember
  case frost
  case moss
  case rose

  var id: Self { self }

  var label: String {
    switch self {
    case .anvil: "Anvil"
    case .pro: "Pro"
    case .inverse: "Inverse"
    case .ember: "Ember"
    case .frost: "Frost"
    case .moss: "Moss"
    case .rose: "Rose"
    }
  }

  /// What iOS is asked for: nil means the primary icon.
  var alternateIconName: String? {
    self == .anvil ? nil : "AppIcon-\(label)"
  }

  /// The icon's own colours, for the picker to draw a small version of it.
  var colors: (background: Color, mark: Color) {
    switch self {
    // The same in both apps: the mark in white on black, and Inverse the other way round. The
    // development app used to wear the inverted one to tell it apart; its name under the icon
    // does that.
    case .anvil: (.black, .white)
    case .pro: (.black, Color(red: 0.98, green: 0.80, blue: 0.30))  // the chooser draws the gold mark
    case .inverse: (.white, .black)
    case .ember: (.black, AppTheme.ember.swatch)
    case .frost: (.black, AppTheme.frost.swatch)
    case .moss: (.black, AppTheme.moss.swatch)
    case .rose: (.black, AppTheme.rose.swatch)
    }
  }
}
