import SwiftUI

/// The gold block, modelled: the one picture in the app, for the one page that sells something.
///
/// The rendered gold from the design, with its background cut away so it sits on whatever the
/// page is, and still. Everywhere else Pro is named, the flat ``GoldAnvil`` stands for it.
struct GoldBlock: View {
  var size: CGFloat = 132

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
  GoldBlock()
    .padding()
}
