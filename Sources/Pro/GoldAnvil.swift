import SwiftUI

/// The mark in gold: Anvil Pro's mark on the rows that name it — the row in Settings that leads
/// to Pro, the line that says it is active, the Pro icon in the picker.
///
/// The same ``AnvilShape`` as everywhere else, flat on the page, its face a gold gradient. Still:
/// a pixel mark stays a pixel mark. The one place Pro is being sold, the Pro page, shows the
/// modelled gold block instead — see ``GoldBlock``.
struct GoldAnvil: View {
  var size: CGFloat = 56

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
