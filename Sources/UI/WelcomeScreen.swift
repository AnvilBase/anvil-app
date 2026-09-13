import SwiftUI

/// The first thing a new install shows: what the app is, in three lines, before it asks for
/// anything at all.
///
/// It is shown once — **Continue** writes that down — so it is not a gate and not a tour. It is
/// there because the one thing worth knowing about this app is where the work happens and what
/// leaves the phone, and that is easier to say plainly on an empty screen than to discover later in
/// Settings.
struct WelcomeScreen: View {
  @Environment(\.theme) private var theme
  let onContinue: () -> Void

  /// Anvil in both builds: this screen is the product introducing itself, and the development app
  /// is the same product. Saying "Welcome to Anvil Dev" here made it read as a second app.
  private var productName: String { AppFlavor.productName }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 44) {
        title
        VStack(alignment: .leading, spacing: 30) {
          ForEach(points) { point in
            row(point)
          }
        }
      }
      .padding(.horizontal, 24)
      .padding(.top, 40)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(theme.page)
    .safeAreaInset(edge: .bottom) { continueButton }
  }

  // MARK: - The mark and the name

  private var title: some View {
    VStack(spacing: 26) {
      // The mark itself, the same one the drawer carries, just larger. Nothing is coloured on this
      // screen: the anvil and the name are the one shape you are meant to come away with.
      PixelAnvil(size: 68)
      VStack(spacing: 0) {
        Text("Welcome to")
        Text(productName)
      }
      .font(.largeTitle.bold())
      .multilineTextAlignment(.center)
      // Text here is already two steps up from the system default (see `AnvilRootScene`), and this
      // is the largest type in the app. Rather than wrap the name onto a second line, let it close
      // up.
      .minimumScaleFactor(0.6)
      .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - What the app is

  /// Three things, and the order is the argument: it runs here, so nothing goes out, so here is the
  /// short list of what does.
  private var points: [Point] {
    [
      Point(
        symbol: "sparkles",
        title: "Offline assistant",
        detail:
          "A model runs entirely on this iPhone. No account, no sign-in, and no internet needed to "
          + "chat."),
      Point(
        symbol: "lock.fill",
        title: "Private and secure",
        detail:
          "Chats are encrypted with your passcode and stay on the phone. No analytics, no "
          + "telemetry, nothing uploaded."),
      Point(
        symbol: "antenna.radiowaves.left.and.right",
        title: "Only two things go out",
        detail:
          "Downloading a model, and web search when you ask for it. You can see both happen, and "
          + "nothing else ever leaves."),
    ]
  }

  private struct Point: Identifiable {
    let symbol: String
    let title: String
    let detail: String

    var id: String { symbol }
  }

  private func row(_ point: Point) -> some View {
    HStack(alignment: .top, spacing: 18) {
      Image(systemName: point.symbol)
        .font(.title2)
        .symbolRenderingMode(.hierarchical)
        // A fixed column, so the three titles start on the same line however wide their glyphs are.
        .frame(width: 34, alignment: .center)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 5) {
        Text(point.title)
          .font(.headline)
        Text(point.detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - Continue

  /// Held out of the scroll view so it stays where it is whatever the type size does to the page
  /// above it: at the largest sizes the three points scroll, and the way on is still under a thumb.
  private var continueButton: some View {
    Button(action: onContinue) {
      Text("Continue")
        .font(.headline)
        .frame(maxWidth: .infinity)
        .frame(height: ChatStyle.control)
        .background(theme.sendFill, in: Capsule())
        .foregroundStyle(theme.sendGlyph)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 24)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .background(theme.page)
  }
}
