import SwiftUI

/// The mark in gold: Anvil Pro's mark on the rows that name it — the row in Settings that leads
/// to Pro, the line that says it is active, the Pro icon in the picker.
///
/// The same ``AnvilShape`` as everywhere else, flat on the page, its face a gold gradient. Still:
/// a pixel mark stays a pixel mark. The one place Pro is being sold, the Pro page, shows the
/// modelled gold block instead — see ``GoldBlock``.
struct GoldAnvil: View {
  var size: CGFloat = 56

  /// What the Pro app icon sits on, for the picker to draw its tile the way the icon is: a warm
  /// dark brown, brightest a little up and to the left of centre — where the light on the face
  /// comes from — and near-black at the corners. Not flat black, which the gold sat on like a
  /// sticker. `Scripts/render-icons.swift` paints the same gradient under the icon itself.
  static let ground = RadialGradient(
    stops: [
      .init(color: Color(red: 0.24, green: 0.18, blue: 0.09), location: 0),
      .init(color: Color(red: 0.13, green: 0.10, blue: 0.05), location: 0.55),
      .init(color: Color(red: 0.06, green: 0.045, blue: 0.025), location: 1),
    ],
    center: UnitPoint(x: 0.38, y: 0.34), startRadius: 0, endRadius: 53)

  private static let face = LinearGradient(
    stops: [
      .init(color: Color(red: 1.00, green: 0.94, blue: 0.66), location: 0),
      .init(color: Color(red: 0.98, green: 0.80, blue: 0.30), location: 0.42),
      .init(color: Color(red: 0.76, green: 0.53, blue: 0.10), location: 0.78),
      .init(color: Color(red: 0.96, green: 0.79, blue: 0.36), location: 1),
    ],
    startPoint: .topLeading, endPoint: .bottomTrailing)

  var body: some View {
    AnvilShape()
      .fill(Self.face)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

#Preview {
  VStack(spacing: 24) {
    GoldAnvil(size: 22)
    GoldAnvil(size: 36)
    GoldAnvil(size: 84)
  }
  .padding()
}
