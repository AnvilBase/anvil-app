import SwiftUI

/// The mark in gold, as a block that catches the light: Anvil Pro's mark, on the row that sells
/// it and the page that does.
///
/// The same ``AnvilShape`` as everywhere else, given a body: the shape is stepped down in dark
/// bronze so it stands off the surface, the top face is a gold gradient with a bevel — light
/// along its upper edges, shade along its lower — and every few seconds a broad, soft band of
/// light crosses the face from its bottom-left corner to its top-right, the way a sheen moves
/// over metal as it tilts. The band is wider than the mark and fades to nothing well outside it,
/// so what shows is light passing over the gold and never the band's own edge. Between
/// crossings, three small glints — four-pointed, the shape a highlight takes through a lens —
/// flash at the corners of the face, each on its own beat, so the mark is never quite still.
/// Drawn, not modelled: a pixel mark extruded is still a pixel mark. Reduce Motion gets the gold
/// and neither the sheen nor the glints.
struct GoldAnvil: View {
  var size: CGFloat = 56

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let face = LinearGradient(
    stops: [
      .init(color: Color(red: 1.00, green: 0.94, blue: 0.66), location: 0),
      .init(color: Color(red: 0.98, green: 0.80, blue: 0.30), location: 0.42),
      .init(color: Color(red: 0.76, green: 0.53, blue: 0.10), location: 0.78),
      .init(color: Color(red: 0.96, green: 0.79, blue: 0.36), location: 1),
    ],
    startPoint: .topLeading, endPoint: .bottomTrailing)

  /// The sides of the block: darker, and darker still further down.
  private static let side = LinearGradient(
    colors: [Color(red: 0.62, green: 0.42, blue: 0.10), Color(red: 0.40, green: 0.26, blue: 0.05)],
    startPoint: .top, endPoint: .bottom)

  /// How often the sheen crosses, and how long a crossing takes. Rare and unhurried: gold
  /// catching the light now and then, not something that glitters.
  private static let period = 5.5
  private static let crossing = 1.8

  /// The band of light, as it lies across a square much larger than the face. The gradient runs
  /// corner to corner — the way the band travels — and is clear for most of its length, so the
  /// square's own edges are never anything but clear wherever they fall over the mark.
  private static let sheen = LinearGradient(
    stops: [
      .init(color: .clear, location: 0),
      .init(color: .clear, location: 0.36),
      .init(color: .white.opacity(0.22), location: 0.46),
      .init(color: .white.opacity(0.62), location: 0.5),
      .init(color: .white.opacity(0.22), location: 0.54),
      .init(color: .clear, location: 0.64),
      .init(color: .clear, location: 1),
    ],
    startPoint: .bottomLeading, endPoint: .topTrailing)

  /// A glint: where it sits on the face, in the face's own unit square (a little past an edge is
  /// fine — a glint overhangs), how often it flashes, when in that cycle, and how big beside the
  /// largest.
  private struct Glint {
    var x: CGFloat
    var y: CGFloat
    var period: Double
    var offset: Double
    var scale: CGFloat
  }

  /// Three, on the corners the light would catch: two along the top edge, one on the base. Their
  /// periods share no factor, so the same two are rarely lit together and the pattern never
  /// settles into a beat.
  private static let glints = [
    Glint(x: 0.13, y: 0.11, period: 4.1, offset: 0.0, scale: 1),
    Glint(x: 0.88, y: 0.26, period: 5.3, offset: 2.3, scale: 0.78),
    Glint(x: 0.83, y: 0.9, period: 6.7, offset: 4.1, scale: 0.66),
  ]

  /// How long one flash lasts, start to end.
  private static let flash = 0.85

  var body: some View {
    if reduceMotion {
      mark(at: nil)
    } else {
      TimelineView(.animation) { context in
        mark(at: context.date.timeIntervalSinceReferenceDate)
      }
    }
  }

  /// How far across the face the sheen is at `time`, 0 at the bottom-left corner to 1 past the
  /// top-right — or nil between crossings, when there is nothing to draw. Eased at both ends, so
  /// the band slows into view and away again rather than snapping.
  private static func sweep(at time: Double) -> Double? {
    let t = time.truncatingRemainder(dividingBy: period)
    guard t < crossing else { return nil }
    let u = t / crossing
    return 0.5 - cos(u * .pi) / 2
  }

  /// How far through its flash a glint is at `time`, 0 to 1 — or nil, when it is dark.
  private static func flash(of glint: Glint, at time: Double) -> Double? {
    let t = (time + glint.offset).truncatingRemainder(dividingBy: glint.period)
    return t < flash ? t / flash : nil
  }

  /// The glints that are lit at `time`, over the face: each grows from nothing and fades away
  /// again, turning a little as it goes, brightest and largest in the middle of its flash.
  private func glints(at time: Double, faceSize: CGFloat, inset: CGFloat) -> some View {
    ZStack {
      ForEach(Array(Self.glints.enumerated()), id: \.offset) { _, glint in
        if let u = Self.flash(of: glint, at: time) {
          let intensity = sin(u * .pi)
          let span = faceSize * 0.24 * glint.scale
          // Soft-edged and never fully opaque: a glint is light on the surface, seen through
          // the eye's own blur, not a white shape laid on top of the gold.
          GlintShape()
            .fill(Color(red: 1, green: 0.98, blue: 0.9))
            .frame(width: span, height: span)
            .scaleEffect(0.25 + 0.75 * intensity)
            .rotationEffect(.degrees(-24 + 48 * u))
            .blur(radius: span * 0.16)
            .opacity(0.65 * intensity)
            .shadow(color: .white.opacity(0.35 * intensity), radius: span * 0.3)
            .position(x: inset + glint.x * faceSize, y: glint.y * faceSize)
        }
      }
    }
  }

  /// The block, and the sheen and glints where they stand at `time` — or, with no time, neither.
  private func mark(at time: Double?) -> some View {
    // The face takes the top of the frame; the depth below it is the body.
    let depth = max(2, (size * 0.11).rounded())
    let faceSize = size - depth
    let steps = Int(depth)

    return ZStack(alignment: .top) {
      // The body, deepest layer first so each sits under the one above it.
      ForEach((1...steps).reversed(), id: \.self) { step in
        AnvilShape()
          .fill(Self.side)
          .frame(width: faceSize, height: faceSize)
          .offset(y: CGFloat(step))
      }
      AnvilShape()
        .fill(
          Self.face
            .shadow(.inner(color: .white.opacity(0.55), radius: faceSize * 0.02, y: faceSize * 0.025))
            .shadow(.inner(color: .black.opacity(0.45), radius: faceSize * 0.05, y: -faceSize * 0.035))
        )
        .frame(width: faceSize, height: faceSize)
        .overlay {
          if let time, let progress = Self.sweep(at: time) {
            // The band, on a square three times the face, slid along the diagonal from well
            // below and left of the mark to well above and right of it. At either end of the
            // trip the lit part of the band is more than a face's width outside the mark, and
            // the square still covers the face throughout, so no edge of anything ever shows.
            let extent = faceSize * 3
            let travel = faceSize * 1.7 * CGFloat(progress * 2 - 1)
            Rectangle()
              .fill(Self.sheen)
              .frame(width: extent, height: extent)
              .offset(x: travel, y: -travel)
              .blendMode(.screen)
          }
        }
        .mask(AnvilShape().frame(width: faceSize, height: faceSize))
    }
    .frame(width: size, height: size, alignment: .top)
    // A light shadow, enough to lift the block off the page and no more.
    .shadow(color: .black.opacity(0.16), radius: size * 0.05, y: size * 0.03)
    .overlay {
      // Over the block rather than inside its mask: a glint sits on a corner and past it.
      if let time {
        glints(at: time, faceSize: faceSize, inset: depth / 2)
      }
    }
    .accessibilityHidden(true)
  }
}

/// A four-pointed star with its sides drawn in toward the centre: the shape a point of light
/// takes through a lens, and the one everything means by a sparkle.
struct GlintShape: Shape {
  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let tips = [
      CGPoint(x: rect.midX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.midY),
      CGPoint(x: rect.midX, y: rect.maxY),
      CGPoint(x: rect.minX, y: rect.midY),
    ]
    var path = Path()
    path.move(to: tips[0])
    for index in 0..<tips.count {
      let next = tips[(index + 1) % tips.count]
      // The control point sits just off centre toward the two tips, so the arms are slender but
      // not knife-thin.
      let control = CGPoint(
        x: center.x + (tips[index].x + next.x - 2 * center.x) * 0.08,
        y: center.y + (tips[index].y + next.y - 2 * center.y) * 0.08)
      path.addQuadCurve(to: next, control: control)
    }
    path.closeSubpath()
    return path
  }
}
