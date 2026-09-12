import SwiftUI

/// The Anvil mark, drawn as the seven-by-seven grid it is, filling in a row at a time.
///
/// Pixel for pixel the mark the site ships as `icons/svg/anvil-current.svg`: a three-row top, a
/// two-row waist three pixels wide, a two-row base. Kept as literal rows rather than decoded from
/// data — it's seven strings, it never changes at runtime, and reading it here is easier than
/// finding the file it came from.
///
/// The rows are drawn edge to edge with nothing between them. It looks like a grid of pixels while
/// it is filling in, and like the solid mark in the icon file once it has — which is the point: it
/// is the same shape, not a lattice version of it.
struct PixelAnvil: View {
  var size: CGFloat = 56
  var color: Color = .primary
  /// Set false to draw it fully lit, with no reveal — for anywhere it isn't the thing being looked
  /// at.
  var animated = true

  private static let rows = [
    "#######",
    "#######",
    "#######",
    "..###..",
    "..###..",
    "#######",
    "#######",
  ]

  @State private var lit = false

  var body: some View {
    let side = size / CGFloat(Self.rows.count)

    VStack(spacing: 0) {
      ForEach(Array(Self.rows.enumerated()), id: \.offset) { row, cells in
        HStack(spacing: 0) {
          ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
            Rectangle()
              .fill(color)
              .frame(width: side, height: side)
              .opacity(cell == "#" ? (lit ? 1 : 0) : 0)
          }
        }
        // A row at a time, top to bottom. One delay, no per-pixel staggering: the mark draws
        // itself and then stands still.
        .animation(.easeOut(duration: 0.2).delay(Double(row) * 0.06), value: lit)
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
