import SwiftUI

/// Anvil Pro: what it is, and the one button that gets it.
///
/// Pushed from the top of Settings. The list says what Pro is in the same shape the empty chat
/// says what the buttons do — a glyph and a line, nothing louder — and the price comes from the
/// App Store, never from the app, so it is right for whichever storefront this is. A build the
/// App Store has no product for says so instead of pretending.
struct ProScreen: View {
  @Environment(ProAccess.self) private var pro
  @Environment(\.theme) private var theme
  @Environment(\.openURL) private var openURL

  var body: some View {
    ScrollView {
      VStack(spacing: 36) {
        VStack(spacing: 14) {
          PixelAnvil(size: 56)
          Text("Anvil Pro")
            .font(.largeTitle.bold())
          Text("The same private assistant, with more of it in your hands.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)

        VStack(alignment: .leading, spacing: 20) {
          ForEach(Self.features, id: \.title) { feature in
            HStack(alignment: .top, spacing: 16) {
              Image(systemName: feature.symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                  .font(.headline)
                Text(feature.line)
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .padding(.horizontal, 24)
      .padding(.top, 24)
      .padding(.bottom, 16)
    }
    .background(theme.page)
    .safeAreaInset(edge: .bottom) { footer }
    .navigationBarTitleDisplayMode(.inline)
  }

  private static let features: [(symbol: String, title: String, line: String)] = [
    ("text.quote", "Your own system prompt", "Tell Anvil who it is and how to answer."),
    ("slider.horizontal.3", "Sampling controls", "Temperature, top-K, top-P and thinking."),
    ("paintpalette", "Themes", "Ember, Frost, Moss and Rose, in light and dark."),
    ("app", "App icons", "The mark in five more colours on your Home Screen."),
    ("faceid", "Face ID lock", "Or your passcode, every time Anvil comes back."),
    ("waveform", "Talk mode", "Replies read aloud on this iPhone, then the mic again."),
  ]

  // MARK: - Subscribe

  /// Held out of the scroll view, the way Continue is on the welcome screen: whatever the type size
  /// does to the list, the way to buy stays under a thumb.
  @ViewBuilder
  private var footer: some View {
    VStack(spacing: 12) {
      if pro.isUnlocked {
        Label("Anvil Pro is active", systemImage: "checkmark.circle.fill")
          .font(.headline)
        Button("Manage subscription") {
          if let url = URL(string: "https://apps.apple.com/account/subscriptions") { openURL(url) }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      } else {
        Button {
          Task { await pro.purchase() }
        } label: {
          Group {
            if pro.isPurchasing {
              ProgressView().tint(theme.sendGlyph)
            } else if let price = pro.displayPrice {
              Text("Subscribe · \(price) a month")
            } else {
              Text("Subscribe")
            }
          }
          .font(.headline)
          .frame(maxWidth: .infinity)
          .frame(height: ChatStyle.control)
          .background(theme.sendFill, in: Capsule())
          .foregroundStyle(theme.sendGlyph)
        }
        .buttonStyle(.plain)
        .disabled(pro.product == nil || pro.isPurchasing)

        if pro.product == nil {
          // An open-source build, or a sandbox with no product yet. Say so rather than showing a
          // button that will never do anything.
          Text("Subscriptions aren't available in this build.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          Text("Renews monthly until cancelled. Cancel any time in Settings › Apple Account.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        // Grey, like every other secondary line in the app, rather than the system's blue: the
        // one coloured thing on this screen is the button that buys.
        Button("Restore purchases") { Task { await pro.restore() } }
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .disabled(pro.isPurchasing)

        if let error = pro.lastError {
          Text(error)
            .font(.footnote)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
        }
      }
    }
    .padding(.horizontal, 24)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .background(theme.page)
  }
}
