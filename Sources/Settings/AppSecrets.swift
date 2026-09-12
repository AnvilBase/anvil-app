import Foundation

/// Keys the build carries, read from the app bundle rather than from a source file.
///
/// The value comes from `ANVIL_BRAVE_API_KEY` in `Config/Local.xcconfig`, which git ignores, so a
/// fresh clone builds and runs with no setup and nobody can commit a key by accident. Anyone with a
/// copy of a build can still extract a key from it, so don't share builds that carry yours.
enum AppSecrets {
  /// Brave Search key used by web search. Empty means web search stays off.
  static let braveSearchAPIKey: String = {
    let value = Bundle.main.infoDictionary?["BraveSearchAPIKey"] as? String ?? ""
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    // An unset build setting can reach the bundle as the literal "$(ANVIL_BRAVE_API_KEY)".
    return trimmed.hasPrefix("$(") ? "" : trimmed
  }()

  static var hasBraveSearchKey: Bool { !braveSearchAPIKey.isEmpty }
}
