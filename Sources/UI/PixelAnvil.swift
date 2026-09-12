import SwiftUI

/// The Anvil mark, drawn as the seven-by-seven grid it is.
///
/// Pixel for pixel the mark the site ships as `icons/svg/anvil-current.svg`: a three-row top, a
/// two-row waist three pixels wide, a two-row base. Kept as literal rows rather than decoded from
/// data — it's seven strings, it never changes at runtime, and reading it here is easier than
/// finding the file it came from.
///
/// The rows are drawn edge to edge with nothing between them, so what comes out is the solid mark
/// in the icon file rather than a lattice version of it. It used to fill itself in a row at a time
/// when it appeared; it doesn't any more. A mark is a thing that is simply there.
struct PixelAnvil: View {
  var size: CGFloat = 56
  var color: Color = .primary

  /// Shared with ``AnvilStrike``, which animates the same seven strings rather than keeping a
  /// second copy of the mark.
  static let rows = [
    "#######",
    "#######",
    "#######",
    "..###..",
    "..###..",
    "#######",
    "#######",
  ]

  var body: some View {
    let side = size / CGFloat(Self.rows.count)

    VStack(spacing: 0) {
      ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, cells in
        HStack(spacing: 0) {
          ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
            Rectangle()
              .fill(color)
              .frame(width: side, height: side)
              .opacity(cell == "#" ? 1 : 0)
          }
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
