import SwiftUI

/// The mark with light moving over it: the same seven-by-seven grid ``PixelAnvil`` draws, with two
/// slow waves crossing it at different angles and different speeds.
///
/// ``PixelAnvil`` is deliberately still — a mark is a thing that is simply there — so this is a
/// separate view rather than a flag on it, and it is used in the one place where the mark is being
/// introduced rather than simply worn: the welcome screen.
///
/// Waves, not static: how lit a block is depends on where it is, so neighbours move together and a
/// crest travels through the iron as one piece. But there are two of them, at different angles and
/// on periods that don't divide into each other, so they drift in and out of step for as long as
/// the screen is up — the crests come through from one way, then another, and the pattern never
/// comes back round to where it began. Nothing moves and nothing changes size: only how lit each
/// block is, so what you are watching is always the mark and never a pile of squares.
struct AnvilWave: View {
  var size: CGFloat = 68
  var color: Color = .primary

  /// How far down a block goes. Never dark: the mark has to stay readable as a mark the whole way
  /// round, and this is meant to read as light crossing iron rather than as blocks being switched.
  private let trough = 0.38

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if reduceMotion {
      // Reduce Motion asks for the mark, not the light moving over it.
      PixelAnvil(size: size, color: color)
    } else {
      TimelineView(.animation) { context in
        grid(at: context.date.timeIntervalSinceReferenceDate)
      }
    }
  }

  private func grid(at time: TimeInterval) -> some View {
    let side = size / CGFloat(PixelAnvil.rows.count)

    return VStack(spacing: 0) {
      ForEach(Array(PixelAnvil.rows.enumerated()), id: \.offset) { row, cells in
        HStack(spacing: 0) {
          ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
            Rectangle()
              .fill(color)
              // Edge to edge, so what stands there is the solid mark and not a lattice of it.
              .frame(width: side, height: side)
              .opacity(cell == "#" ? litness(row: row, column: column, time: time) : 0)
          }
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  /// The two waves, added together and folded into a brightness.
  ///
  /// Each is a plane wave: a direction across the grid, a speed, and a phase. The first comes down
  /// the mark and slightly across, the second across it and slightly up. The spatial numbers are
  /// about one wavelength over the seven blocks, so you see a crest pass through rather than the
  /// whole mark brightening at once; the speeds are slow, and deliberately not multiples of each
  /// other.
  private func litness(row: Int, column: Int, time: TimeInterval) -> Double {
    let row = Double(row)
    let column = Double(column)
    let first = sin(row * 0.85 + column * 0.45 - time * 0.5)
    let second = sin(column * 0.9 - row * 0.35 - time * 0.33 + 1.7)
    // -1...1 down to 0...1, then lifted off the floor.
    let crest = (first + second) / 4 + 0.5
    return trough + crest * (1 - trough)
  }
}
