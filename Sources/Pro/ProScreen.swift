import StoreKit
import SwiftUI

/// Anvil Pro: what it is, and the one button that gets it.
///
/// Pushed from the top of Settings. Scrolls on smaller phones and at larger text sizes: the mark,
/// the name, eight lines, and
/// two ways to pay, a year or a month — with prices that come from the App Store, never from the
/// app, so they are right for whichever storefront this is. A build the App Store has no products
/// for says so instead of pretending.
struct ProScreen: View {
  @Environment(ProAccess.self) private var pro
  @Environment(ModelLibrary.self) private var library
  @Environment(\.theme) private var theme
  @Environment(\.openURL) private var openURL

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        Spacer(minLength: 8)
        // The modelled gold block, and large: this is the page that sells Pro, and the block is
        // what it is selling. The feature list can scroll while the purchase controls stay visible.
        GoldBlock(size: 136)
        Text("Anvil Pro")
          .font(.system(size: 34, weight: .bold))
          .padding(.top, 14)
        VStack(alignment: .leading, spacing: 14) {
          ForEach(Self.features, id: \.title) { feature in
            HStack(spacing: 16) {
              Image(systemName: feature.symbol)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(.secondary)
              Text(feature.title)
                .font(.body.weight(.semibold))
            }
          }
        }
        .padding(.top, 26)
        Spacer(minLength: 8)
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 24)
      .padding(.vertical, 12)
    }
    .background(theme.page)
    .safeAreaInset(edge: .bottom) { footer }
    .navigationBarTitleDisplayMode(.inline)
  }

  /// Each line is one thing Pro is, named in as few words as say it: the line stays whole on one
  /// line, which a sentence would not. No model names here — Pro is one model, and these are the
  /// things it does.
  private static let features: [(symbol: String, title: String)] = [
    ("lock.open", "Unrestricted Answers"),
    ("paintbrush", "Image Generation"),
    ("text.quote", "Custom System Prompt"),
    ("slider.horizontal.3", "Sampling Controls"),
    ("paintpalette", "Themes"),
    ("app", "App Icons"),
    ("lock", "Passcode Lock"),
    ("waveform", "Talk Mode"),
  ]

  // MARK: - Subscribe

  @ViewBuilder
  private var footer: some View {
    VStack(spacing: 10) {
      if pro.isUnlocked {
        if let plan = library.installingPro {
          // Bought, and already on its way down. What is left to know is how far it has got and
          // that walking away doesn't stop it — the download outlives this screen.
          ProgressView(value: library.progress(of: plan)?.fraction ?? 0)
            .tint(theme.sendFill)
          Text("Anvil Pro is downloading. You can leave this screen.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        } else {
          Label("Anvil Pro is active", systemImage: "checkmark.circle.fill")
            .font(.headline)
        }
        Button("Manage subscription") {
          if let url = URL(string: "https://apps.apple.com/account/subscriptions") { openURL(url) }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      } else {
        // The year first and filled, the month under it in outline: the year is the better deal
        // and the button says by how much. Without products there is one button that does
        // nothing, and the line under it says why.
        if let yearly = pro.yearly {
          subscribeButton(
            for: yearly, label: "\(yearly.displayPrice) a year",
            tag: pro.yearlySavingsPercent.map { "Save \($0)%" }, filled: true)
        }
        if let monthly = pro.monthly {
          subscribeButton(
            for: monthly, label: "\(monthly.displayPrice) a month", tag: nil,
            filled: pro.yearly == nil)
        }
        if !pro.isAvailable {
          Button {} label: { subscribeLabel("Subscribe", tag: nil, filled: true) }
            .buttonStyle(.plain)
            #if ANVIL_DEV
              // The development app can't buy a product, so holding Subscribe stands in for it:
              // Pro switches on for this run, the way the developer screen's preview does. The
              // button stays pressable without a product for that reason alone; a tap still does
              // nothing. Compiled out of the public app, not hidden in it.
              .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.8).onEnded { _ in pro.previewUnlocked = true }
              )
              .sensoryFeedback(.success, trigger: pro.previewUnlocked)
            #else
              .disabled(true)
            #endif
        }

        // One line, and it is the one App Review asks for. Without a product it is the one that
        // says why the button above does nothing.
        Text(pro.isAvailable ? "Renews automatically. Cancel any time." : "Not available in this build.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        #if ANVIL_DEV
          Text("Hold Subscribe to preview Pro in this build.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
        #endif

        HStack(spacing: 18) {
          Button("Restore purchases") { Task { await subscribe { await pro.restore() } } }
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

  /// Pays, or restores, and then fetches what was paid for. Anvil Pro is a subscription and a pair
  /// of files, and pressing a price should get you both: nobody should have to buy Pro and then go
  /// and find the thing that downloads it. `installPro` is the one that decides there is anything
  /// to fetch — it does nothing when Pro is already on the phone, as it is after a restore on a
  /// phone that already had it.
  private func subscribe(_ pay: () async -> Void) async {
    await pay()
    guard pro.isUnlocked else { return }
    await library.installPro()
  }

  /// One way to pay: a capsule with the price and, for the year, what it saves. Filled for the one
  /// the screen recommends, outlined for the other, so the pair reads as a choice and not two
  /// asks. Both are Pro; the App Store moves a subscriber between them.
  private func subscribeButton(for product: Product, label: String, tag: String?, filled: Bool)
    -> some View
  {
    Button {
      Task { await subscribe { await pro.purchase(product) } }
    } label: {
      subscribeLabel(label, tag: tag, filled: filled)
    }
    .buttonStyle(.plain)
    .disabled(pro.isPurchasing)
  }

  @ViewBuilder
  private func subscribeLabel(_ text: String, tag: String?, filled: Bool) -> some View {
    let foreground: Color = filled ? theme.sendGlyph : theme.sendFill
    HStack(spacing: 10) {
      if pro.isPurchasing, filled {
        ProgressView().tint(foreground)
      } else {
        Text(text)
        if let tag {
          Text(tag)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(foreground.opacity(0.6), lineWidth: 1))
            .fixedSize()
        }
      }
    }
    .font(.headline)
    .frame(maxWidth: .infinity)
    .frame(height: ChatStyle.control)
    .background {
      if filled {
        Capsule().fill(theme.sendFill)
      } else {
        Capsule().strokeBorder(theme.sendFill, lineWidth: 1.5)
      }
    }
    .foregroundStyle(foreground)
  }
}
