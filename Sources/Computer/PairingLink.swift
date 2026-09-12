import Foundation

/// The link behind the companion server's pairing QR code:
/// `anvil://pair?url=https://your-computer.tailnet.ts.net&token=…`
///
/// Scanning it with the Camera app opens the app, which asks before saving anything, so a stray code
/// can't quietly redirect your replies somewhere else. The development app answers to `anvil-dev`
/// instead, which is how one QR code targets one app.
struct PairingLink: Equatable {
  let url: URL
  let token: String

  init?(url link: URL) {
    guard link.scheme?.lowercased() == AppFlavor.urlScheme.lowercased(),
      link.host()?.lowercased() == "pair",
      let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
      let address = items.first(where: { $0.name == "url" })?.value
        .flatMap(ComputerAddress.url(from:)),
      let token = items.first(where: { $0.name == "token" })?.value?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else { return nil }
    url = address
    self.token = token
  }
}
