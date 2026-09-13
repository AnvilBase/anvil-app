import SwiftUI

/// The Anvil mark, drawn as the seven-by-seven grid it is.
///
/// Pixel for pixel the mark the site ships as `icons/svg/anvil-current.svg`: a three-row top, a
/// two-row waist three pixels wide, a two-row base. Kept as literal rows rather than decoded from
/// data — it's seven strings, it never changes at runtime, and reading it here is easier than
/// finding the file it came from.
///
/// One shape, not a grid of views. It was forty-nine `Rectangle`s once, and a grid of views is a
/// grid of things that can each be animated: dropped into a screen that is mid-spring — a new chat
/// opening, say — every block took the spring on its own and the mark assembled itself in front of
/// you. A mark is a thing that is simply there. As a single path there is nothing for an
/// animation to get between, so it arrives whole wherever it is put, however that place is moving.
struct PixelAnvil: View {
  var size: CGFloat = 56
  var color: Color = .primary

  var body: some View {
    AnvilShape()
      .fill(color)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// The mark as a path: one rectangle per filled cell, edge to edge, in the one shape. Cells that
/// touch share an edge exactly, so the fill runs across them without a seam — what comes out is the
/// solid mark in the icon file rather than a lattice version of it.
private struct AnvilShape: Shape {
  private static let rows = [
    "#######",
    "#######",
    "#######",
    "..###..",
    "..###..",
    "#######",
    "#######",
  ]

  func path(in rect: CGRect) -> Path {
    let side = min(rect.width, rect.height) / CGFloat(Self.rows.count)
    var path = Path()
    for (row, cells) in Self.rows.enumerated() {
      for (column, cell) in cells.enumerated() where cell == "#" {
        path.addRect(
          CGRect(
            x: rect.minX + CGFloat(column) * side,
            y: rect.minY + CGFloat(row) * side,
            width: side,
            height: side))
      }
    }
    return path
  }
}
