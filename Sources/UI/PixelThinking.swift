import SwiftUI

/// The waiting indicator: a three-by-three grid of pixels with a pulse travelling across it
/// diagonally, drawn from the same blocks as ``PixelAnvil`` so waiting looks like the rest of the
/// app rather than like a stock spinner.
struct PixelThinking: View {
  var size: CGFloat = 18
  var color: Color = .secondary

  private static let side = 3

  @State private var pulsing = false

  var body: some View {
    let side = size / CGFloat(Self.side)
    // The same hairline ``PixelAnvil`` leaves, so these read as pixels at this smaller size too.
    let gap = max(side * 0.08, 0.5)

    VStack(spacing: 0) {
      ForEach(0..<Self.side, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<Self.side, id: \.self) { column in
            Rectangle()
              .fill(color)
              .frame(width: side - gap, height: side - gap)
              .frame(width: side, height: side)
              .opacity(pulsing ? 1 : 0.15)
              .scaleEffect(pulsing ? 1 : 0.5)
              // Top-left to bottom-right, one diagonal at a time, then back again — a wave
              // crossing the grid for as long as there is nothing to show yet.
              .animation(
                .easeInOut(duration: 0.5)
                  .repeatForever(autoreverses: true)
                  .delay(Double(row + column) * 0.12),
                value: pulsing)
          }
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
    .onAppear { pulsing = true }
  }
}
