import Foundation

/// Every address the app sends you out to, in one place.
///
/// The community links go through anvilai.com rather than naming a server or a handle here, so a
/// moved Discord or a renamed account is a redirect on the site and not a new build. The legal
/// links are the ones App Review asks a subscription screen to carry, and Settings › About shows
/// the same ones.
enum AppLinks {
  static let discord = URL(string: "https://www.anvilai.com/discord")!
  static let x = URL(string: "https://www.anvilai.com/x")!
  static let instagram = URL(string: "https://www.anvilai.com/instagram")!

  /// Apple's standard terms for a subscription.
  static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
  /// The policy the app is built to.
  static let privacy = URL(string: "https://github.com/AnvilBase/anvil-app/blob/main/PRIVACY.md")!
  /// The app's own licence. Model licences are shown with each model, in the catalog.
  static let licenses = URL(string: "https://github.com/AnvilBase/anvil-app/blob/main/LICENSE")!
}
