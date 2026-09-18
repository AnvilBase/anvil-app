import SwiftUI

/// The waiting indicator for a picture: a brush, sweeping. The grid of pixels says the model is
/// thinking; this says it is painting, which is a different kind of wait — longer, and with a
/// thing at the end of it — and deserves its own sign rather than the same one.
///
/// The brush rocks through a short arc about its handle, as a hand would, and a wash of colour
/// rises and fades under it as if from the stroke. Nothing spins: a spinner is a stock part, and
/// this is the app's own.
struct PixelPainting: View {
  var size: CGFloat = 18
  var color: Color = .secondary

  @State private var stroking = false

  var body: some View {
    ZStack {
      // The stroke, laid under the brush and breathing with it: the mark being made.
      RoundedRectangle(cornerRadius: size * 0.12)
        .fill(color.opacity(stroking ? 0.28 : 0.06))
        .frame(width: size * 0.95, height: size * 0.32)
        .offset(y: size * 0.34)
        .scaleEffect(x: stroking ? 1 : 0.55, anchor: .leading)
      Image(systemName: "paintbrush.fill")
        .font(.system(size: size * 0.92, weight: .medium))
        .foregroundStyle(color)
        // Hinged near the handle end, so the bristles travel and the hand stays.
        .rotationEffect(.degrees(stroking ? 14 : -14), anchor: .topTrailing)
        .offset(x: stroking ? size * 0.12 : -size * 0.12)
    }
    .frame(width: size * 1.2, height: size * 1.2)
    .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: stroking)
    .accessibilityHidden(true)
    .onAppear { stroking = true }
  }
}
