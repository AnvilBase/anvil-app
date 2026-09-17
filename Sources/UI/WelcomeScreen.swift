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
    // Centred on the page, with room to scroll only if the type is set large enough to need it.
    GeometryReader { proxy in
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: proxy.size.height)
      }
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
      // One line, always. Text here is already two steps up from the system default (see
      // `AnvilRootScene`), and this is the largest type in the app: rather than wrap onto a second
      // line at the biggest sizes, it closes up to fit.
      Text("Welcome to \(productName)")
        .font(.largeTitle.bold())
        .minimumScaleFactor(0.6)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - What the app is

  /// Three things, each with the one line it needs.
  private var points: [Point] {
    [
      Point(
        symbol: "lock.fill",
        title: "Private & Secure",
        detail: "Chats are encrypted with your passcode and stay on this iPhone."),
      Point(
        symbol: "airplane",
        title: "Works Offline",
        detail: "Download a model once, then chat without an account or internet connection."),
      Point(
        symbol: "vault",
        title: "You're in Control",
        detail: "No analytics or telemetry. Optional web search sends search queries to Anvil and Brave."),
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
      glyph(point.symbol)
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

  /// The mark beside a point: an SF Symbol by name, or the vault, which is the app's own shape and
  /// is drawn in the same ink and at the same size as the symbols beside it.
  @ViewBuilder
  private func glyph(_ symbol: String) -> some View {
    if symbol == "vault" {
      VaultGlyph()
        .fill(Color.primary, style: FillStyle(eoFill: true))
        .frame(width: 28, height: 28)
    } else {
      Image(systemName: symbol)
        .font(.title2)
        // Solid, one colour: a glyph drawn in layers reads as a picture, and these are marks.
        .symbolRenderingMode(.monochrome)
    }
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
