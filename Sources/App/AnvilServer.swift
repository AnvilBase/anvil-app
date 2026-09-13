import Foundation

/// Where anvilai.com is, for this build: the model catalog and the web search relay both live there.
///
/// The host comes from `ANVIL_HOST` in `Config/Shared.xcconfig` by way of the bundle, so a fork can
/// point the app at its own deployment without touching any Swift. It is the host alone because an
/// xcconfig treats `//` as the start of a comment.
enum AnvilServer {
  private static let fallbackHost = "www.anvilai.com"

  static let host: String = {
    let configured = (Bundle.main.infoDictionary?["AnvilHost"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // An unset build setting can reach the bundle as the literal "$(ANVIL_HOST)".
    return configured.isEmpty || configured.hasPrefix("$(") ? fallbackHost : configured
  }()

  /// `https://` + the host + the path, which starts with a slash.
  static func url(_ path: String) -> URL {
    URL(string: "https://\(host)\(path)") ?? URL(string: "https://\(fallbackHost)\(path)")!
  }
}
