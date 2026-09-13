import SwiftUI

/// Anvil Pro: what it is, and the one button that gets it.
///
/// Pushed from the top of Settings. One screen, no scrolling: the mark, the name, six lines, and
/// the price — which comes from the App Store, never from the app, so it is right for whichever
/// storefront this is. A build the App Store has no product for says so instead of pretending.
struct ProScreen: View {
  @Environment(ProAccess.self) private var pro
  @Environment(\.theme) private var theme
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 12)
      GoldAnvil(size: 84)
      Text("Anvil Pro")
        .font(.system(size: 40, weight: .bold))
        .padding(.top, 22)
      VStack(alignment: .leading, spacing: 22) {
        ForEach(Self.features, id: \.title) { feature in
          HStack(spacing: 18) {
            Image(systemName: feature.symbol)
              .font(.title2)
              .frame(width: 34)
              .foregroundStyle(.secondary)
            Text(feature.title)
              .font(.title3.weight(.semibold))
            if let tag = feature.tag {
              Text(tag)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                .fixedSize()
            }
          }
        }
      }
      .padding(.top, 40)
      Spacer(minLength: 12)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .background(theme.page)
    .safeAreaInset(edge: .bottom) { footer }
    .navigationBarTitleDisplayMode(.inline)
  }

  /// Each line is a name, and for a model a capsule after it saying what the name means: the name
  /// stays whole on one line, which a sentence would not.
  private static let features: [(symbol: String, title: String, tag: String?)] = [
    ("lock.open", "Anvil Raw", "Unrestricted"),
    ("paintbrush", "Anvil Dream", "Image"),
    ("text.quote", "Custom System Prompt", nil),
    ("slider.horizontal.3", "Sampling Controls", nil),
    ("paintpalette", "Themes", nil),
    ("app", "App Icons", nil),
    ("lock", "Passcode Lock", nil),
    ("waveform", "Talk Mode", nil),
  ]

  // MARK: - Subscribe

  @ViewBuilder
  private var footer: some View {
    VStack(spacing: 10) {
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

        // One line, and it is the one App Review asks for. Without a product it is the one that
        // says why the button above does nothing.
        Text(pro.product == nil ? "Not available in this build." : "Renews monthly. Cancel any time.")
          .font(.footnote)
          .foregroundStyle(.secondary)

        HStack(spacing: 18) {
          Button("Restore purchases") { Task { await pro.restore() } }
            .disabled(pro.isPurchasing)
          // What App Review asks a subscription screen to link to, along with the renewal line.
          Link("Privacy", destination: AppLinks.privacy)
          Link("Terms", destination: AppLinks.terms)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)

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
