import SwiftUI

/// What the microphone is hearing, as five blocks that rise and fall with it — drawn from the same
/// squared-off pixels as ``PixelAnvil`` and ``PixelThinking``, so listening looks like the rest of
/// the app rather than like a stock level meter.
///
/// There is no timer behind it and nothing repeating: every bar is a function of the level coming
/// off the microphone, which is the point. It moves when you speak and sits still when you don't,
/// so it says *you are being heard* rather than merely *something is on*.
struct SpeechWave: View {
  /// Nought to one, straight from ``SpeechInput``.
  let level: CGFloat
  var height: CGFloat = 20
  var color: Color = .primary

  /// How much of the level each bar takes. The middle hears the most, which is what makes the row
  /// read as a wave rather than as five copies of one bar.
  private static let share: [CGFloat] = [0.45, 0.8, 1, 0.8, 0.45]
  private static let barWidth: CGFloat = 3

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(Self.share.enumerated()), id: \.offset) { index, share in
        Capsule(style: .continuous)
          .fill(color)
          .frame(width: Self.barWidth, height: barHeight(share))
          // Each bar a beat behind the one before it, so a word travels out from the middle
          // instead of the whole row jumping at once.
          .animation(
            .snappy(duration: 0.16).delay(Double(abs(index - 2)) * 0.04), value: level)
      }
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }

  /// Never nothing: at rest the bars are a row of dots, so the row keeps its shape between words.
  private func barHeight(_ share: CGFloat) -> CGFloat {
    let floor = Self.barWidth
    return floor + (height - floor) * min(max(level, 0), 1) * share
  }
}

#Preview {
  VStack(spacing: 20) {
    SpeechWave(level: 0)
    SpeechWave(level: 0.4)
    SpeechWave(level: 1)
  }
  .padding()
}
