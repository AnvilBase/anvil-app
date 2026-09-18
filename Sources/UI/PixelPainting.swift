import SwiftUI

/// The waiting indicator for a picture: a brush, painting, drawn in the same pixels as the mark
/// and the thinking grid. The grid of pixels says the model is thinking; this says it is painting,
/// which is a different kind of wait — longer, and with a thing at the end of it — and deserves
/// its own sign rather than the same one.
///
/// Everything moves a whole cell at a time. The brush steps across the canvas, dabbing as it goes,
/// and a stroke of colour lengthens under its bristles; at the end of the sweep it holds a moment,
/// then the stroke is wiped and it starts again. Nothing is interpolated: a sprite that slides
/// smoothly between cells stops being a sprite, so the frames are picked from a clock rather than
/// animated between, the way a hand-drawn cycle is.
struct PixelPainting: View {
  var size: CGFloat = 18
  var color: Color = .secondary

  /// The brush, seven cells square: a two-wide handle from the top right down to a ferrule, and
  /// bristles that widen towards the bottom left, where the stroke is made.
  private static let brush = [
    ".....##",
    "....##.",
    "...##..",
    "..###..",
    ".####..",
    "####...",
    "###....",
  ]
  private static let brushSide = 7
  /// The bristles' width along the bottom row of the sprite, which is how much stroke lies under
  /// them before the brush has moved at all.
  private static let bristles = 3

  private static let rows = 8
  /// How far the brush travels, in cells, before the stroke is wiped and it starts again.
  private static let sweep = 5
  private static let columns = brushSide + sweep
  /// Frames of holding at the end of the sweep, the finished stroke under a still brush.
  private static let hold = 2
  private static let period = sweep + 1 + hold
  private static let frameLength: TimeInterval = 0.14

  var body: some View {
    let cell = size / CGFloat(Self.rows)
    // The same hairline ``PixelThinking`` leaves, so these read as pixels at this size too.
    let gap = max(cell * 0.08, 0.5)
    TimelineView(.periodic(from: .now, by: Self.frameLength)) { context in
      let step = Int(context.date.timeIntervalSinceReferenceDate / Self.frameLength) % Self.period
      let travel = min(step, Self.sweep)
      // A dab every other frame: the brush drops a cell onto the stroke and lifts again.
      let dab = step % 2 == 1 && step <= Self.sweep ? 1 : 0
      Canvas { graphics, _ in
        func fill(column: Int, row: Int, _ shade: Color) {
          let rect = CGRect(
            x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell - gap, height: cell - gap)
          graphics.fill(Path(rect), with: .color(shade))
        }
        // The stroke first, so the bristles come down on top of it.
        for column in 0..<(travel + Self.bristles) {
          fill(column: column, row: Self.rows - 1, color.opacity(0.35))
        }
        for (row, cells) in Self.brush.enumerated() {
          for (column, cell) in cells.enumerated() where cell == "#" {
            fill(column: column + travel, row: row + dab, color)
          }
        }
      }
    }
    .frame(width: cell * CGFloat(Self.columns), height: size)
    .accessibilityHidden(true)
  }
}
