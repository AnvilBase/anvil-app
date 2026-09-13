import SwiftUI

/// Anvil Pro's mark: the gold block, on the row that sells it and the page that does.
///
/// A picture, not a drawing — the rendered gold from the design, with its background cut away so
/// it sits on whatever the page is — and still. It is the one thing in the app that is modelled
/// rather than drawn in pixels, and that is the point of it: gold reads as gold.
struct GoldAnvil: View {
  var size: CGFloat = 56

  var body: some View {
    Image("ProMark")
      .resizable()
      .interpolation(.high)
      .scaledToFit()
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
