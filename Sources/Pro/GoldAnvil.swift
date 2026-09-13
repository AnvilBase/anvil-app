import SwiftUI

/// The mark in gold, as a block that sparkles: Anvil Pro's mark, on the row that sells it and
/// the page that does.
///
/// The same ``AnvilShape`` as everywhere else, given a body: the shape is stepped down in dark
/// bronze so it stands off the surface, the top face is a gold gradient with a bevel — light
/// along its upper edges, shade along its lower — and a few small points of light on that face
/// each come and go on their own slow clock, never more than one or two at once, so it reads as
/// gold catching the light rather than as anything shining or blinking. Drawn, not modelled: a
/// pixel mark extruded is still a pixel mark. Reduce Motion gets the gold and no sparkle.
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

  /// Where the sparkles sit on the face, as fractions of it, and when in the cycle each one
  /// lights. Every point lands on a filled cell of the seven-by-seven mark, and the phases are
  /// spread so the points take turns rather than lighting together.
  private static let sparkles: [(x: CGFloat, y: CGFloat, phase: Double)] = [
    (0.22, 0.17, 0.00),
    (0.79, 0.32, 0.38),
    (0.50, 0.58, 0.71),
    (0.31, 0.86, 0.19),
    (0.72, 0.84, 0.55),
    (0.58, 0.12, 0.87),
  ]

  /// How long one full round of sparkles takes, and how long any one of them is lit for. Slow
  /// and short-lived: a point catching the light, not a flash.
  private static let period = 7.0
  private static let life = 1.3

  var body: some View {
    if reduceMotion {
      mark(at: nil)
    } else {
      TimelineView(.animation) { context in
        mark(at: context.date.timeIntervalSinceReferenceDate)
      }
    }
  }

  /// How lit a sparkle with `phase` is at `time`, 0 to 1: rises and falls once per period, and
  /// sits dark the rest of the time.
  private static func brightness(phase: Double, at time: Double) -> Double {
    let t = (time - phase * period).truncatingRemainder(dividingBy: period)
    let u = (t < 0 ? t + period : t) / life
    guard u < 1 else { return 0 }
    return sin(u * .pi)
  }

  /// The block, and its sparkles as they stand at `time` — or, with no time, none.
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
          if let time {
            // Small and quiet: each sparkle is a four-point star no wider than a cell, at most
            // about half strength, growing a little as it brightens and shrinking as it goes,
            // with a soft dot behind it so the points don't read as a hard mark.
            ForEach(Array(Self.sparkles.enumerated()), id: \.offset) { _, sparkle in
              let level = Self.brightness(phase: sparkle.phase, at: time)
              if level > 0 {
                let extent = faceSize * 0.13 * (0.6 + 0.4 * level)
                ZStack {
                  Circle()
                    .fill(.white.opacity(0.35 * level))
                    .frame(width: extent * 0.45, height: extent * 0.45)
                    .blur(radius: extent * 0.12)
                  SparkleShape()
                    .fill(.white.opacity(0.6 * level))
                    .frame(width: extent, height: extent)
                }
                .position(x: faceSize * sparkle.x, y: faceSize * sparkle.y)
                .blendMode(.screen)
              }
            }
          }
        }
        .mask(AnvilShape().frame(width: faceSize, height: faceSize))
    }
    .frame(width: size, height: size, alignment: .top)
    .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.05)
    .accessibilityHidden(true)
  }
}

/// A four-point star with drawn-in sides: the shape a point of light on metal takes.
private struct SparkleShape: Shape {
  func path(in rect: CGRect) -> Path {
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let r = min(rect.width, rect.height) / 2
    // How far in the sides pull toward the centre; smaller is a sharper star.
    let waist = r * 0.18
    let tips = [
      CGPoint(x: c.x, y: c.y - r),
      CGPoint(x: c.x + r, y: c.y),
      CGPoint(x: c.x, y: c.y + r),
      CGPoint(x: c.x - r, y: c.y),
    ]
    let waists = [
      CGPoint(x: c.x + waist, y: c.y - waist),
      CGPoint(x: c.x + waist, y: c.y + waist),
      CGPoint(x: c.x - waist, y: c.y + waist),
      CGPoint(x: c.x - waist, y: c.y - waist),
    ]
    var path = Path()
    path.move(to: tips[0])
    for i in 0..<4 {
      path.addQuadCurve(to: tips[(i + 1) % 4], control: waists[i])
    }
    path.closeSubpath()
    return path
  }
}
