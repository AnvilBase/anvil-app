import SwiftUI

/// The moment Pro arrives: the gold block coming up out of the dark, "Welcome to Anvil Pro" under
/// it, and then the page you were on, back where you left it.
///
/// Shown once, over everything, the moment a subscription lands — bought, restored, or, in the
/// development app, previewed. It fades in, holds for a breath, and fades out; the screen under
/// it is whatever was there, and the Pro page, which has nothing left to sell, has stepped back
/// behind it to wherever you came from.
struct ProWelcome: View {
  /// Called once the welcome has had its moment, so whoever showed it can take it down.
  let onDone: () -> Void

  @State private var risen = false
  @State private var named = false

  private static let gold = LinearGradient(
    stops: [
      .init(color: Color(red: 1.00, green: 0.94, blue: 0.66), location: 0),
      .init(color: Color(red: 0.98, green: 0.80, blue: 0.30), location: 0.42),
      .init(color: Color(red: 0.76, green: 0.53, blue: 0.10), location: 0.78),
      .init(color: Color(red: 0.96, green: 0.79, blue: 0.36), location: 1),
    ],
    startPoint: .topLeading, endPoint: .bottomTrailing)

  var body: some View {
    ZStack {
      // Black, with a warm glow behind the block: gold on the dark, the way the Pro page has it.
      Color.black
      RadialGradient(
        colors: [Color(red: 0.98, green: 0.80, blue: 0.30).opacity(risen ? 0.28 : 0), .clear],
        center: .center, startRadius: 0, endRadius: 260)
      VStack(spacing: 26) {
        GoldBlock(size: 168)
          .scaleEffect(risen ? 1 : 0.72)
          .opacity(risen ? 1 : 0)
          .shadow(color: Color(red: 0.98, green: 0.80, blue: 0.30).opacity(risen ? 0.45 : 0), radius: 40)
        VStack(spacing: 8) {
          Text("Welcome to")
            .font(.title3.weight(.medium))
            .foregroundStyle(.white.opacity(0.7))
          Text("Anvil Pro")
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(Self.gold)
        }
        .opacity(named ? 1 : 0)
        .offset(y: named ? 0 : 14)
      }
    }
    .ignoresSafeArea()
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Welcome to Anvil Pro")
    .onAppear {
      withAnimation(.spring(duration: 0.7, bounce: 0.28)) { risen = true }
      withAnimation(.easeOut(duration: 0.5).delay(0.35)) { named = true }
    }
    .task {
      // The block rises, the name follows, and the whole holds long enough to be read.
      try? await Task.sleep(for: .seconds(2.4))
      onDone()
    }
  }
}

#Preview {
  ProWelcome {}
}
