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
  /// Why the app exists, in the site's own words.
  static let manifesto = URL(string: "https://www.anvilai.com/manifesto")!

  /// Apple's standard terms for a subscription.
  static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
  /// The policy the app is built to.
  static let privacy = URL(string: "https://github.com/AnvilBase/anvil-app/blob/main/PRIVACY.md")!
  /// The app's own licence. Model licences are shown with each model, in the catalog.
  static let licenses = URL(string: "https://github.com/AnvilBase/anvil-app/blob/main/LICENSE")!

  /// Where a rating goes. Through the site like the community links: the App Store page only
  /// exists once the app is listed, and its address is a redirect there rather than an ID here.
  static let rate = URL(string: "https://www.anvilai.com/rate")!
  /// The inbox feedback and bug reports are addressed to — the one the site's footer gives.
  static let supportEmail = "hello@anvilai.app"

  /// A mail to `supportEmail`, ready to send, with the subject and body filled in. Nil only if the
  /// text can't be put in a URL, which for text this app writes it always can.
  static func mail(subject: String, body: String) -> URL? {
    // RFC 6068: the query is percent-encoded, and "+" is a plus, not a space, so it is encoded too
    // rather than left to whichever reading the mail app takes.
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard let subject = subject.addingPercentEncoding(withAllowedCharacters: allowed),
      let body = body.addingPercentEncoding(withAllowedCharacters: allowed)
    else { return nil }
    return URL(string: "mailto:\(supportEmail)?subject=\(subject)&body=\(body)")
  }
}
