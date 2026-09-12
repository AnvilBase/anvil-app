import SwiftUI

/// The Anvil mark, drawn as the eight-by-eight grid the site draws it from, lighting up a pixel at
/// a time.
///
/// The same grid as `anvil-pixels.json` on anvilai.com, kept as literal rows rather than decoded
/// from data: it's eight strings, it never changes at runtime, and reading it here is easier than
/// finding the file it came from.
struct PixelAnvil: View {
  var size: CGFloat = 30
  var color: Color = .primary
  /// Set false to draw it fully lit, with no reveal — for anywhere it isn't the thing being looked
  /// at.
  var animated = true

  private static let rows = [
    "########",
    "########",
    ".######.",
    "..####..",
    "..####..",
    ".######.",
    "########",
    "########",
  ]

  @State private var lit = false

  var body: some View {
    let side = size / CGFloat(Self.rows.count)
    // A hairline of background between pixels, so it reads as pixels rather than a silhouette.
    let gap = max(side * 0.08, 0.5)

    VStack(spacing: 0) {
      ForEach(Array(Self.rows.enumerated()), id: \.offset) { row, cells in
        HStack(spacing: 0) {
          ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
            Rectangle()
              .fill(color)
              .frame(width: side - gap, height: side - gap)
              .frame(width: side, height: side)
              .opacity(cell == "#" ? (lit ? 1 : 0) : 0)
              .scaleEffect(lit ? 1 : 0.3)
              // Lights up left to right and top to bottom, so the shape assembles itself.
              .animation(
                .snappy(duration: 0.3)
                  .delay(Double(column) * 0.035 + Double(row) * 0.045),
                value: lit)
          }
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
    .onAppear {
      // It ends up lit either way; `animated` only decides whether that happens visibly.
      guard animated else {
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) { lit = true }
        return
      }
      lit = true
    }
  }
}
