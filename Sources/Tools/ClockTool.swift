import Foundation
import LiteRTLM

/// Answers "what time is it" from the iPhone's own clock, in any time zone, without the network.
///
/// Web search can't do this: page snippets and cached answers are never live, so a search for the
/// time in Tokyo returns whatever a page said when it was crawled.
struct CurrentTimeTool: Tool {
  static let name = "get_current_time"
  static let description =
    "Get the current date and time from the phone's clock, in the user's time zone or another one. "
    + "Use this, not web search, for the current time or date anywhere."

  @ToolParam(
    description:
      "IANA time zone such as America/New_York or Asia/Tokyo. Omit for the user's own time zone.")
  var timeZone: String?

  func run() async throws -> Any {
    guard let zone = Self.resolve(timeZone) else {
      return [
        "error": "Unknown time zone \"\(timeZone ?? "")\". Use an IANA name like America/New_York."
      ]
    }
    let now = Date()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
    let offset = zone.secondsFromGMT(for: now)
    return [
      "time_zone": zone.identifier,
      "abbreviation": zone.abbreviation(for: now) ?? "",
      "local_time": formatter.string(from: now),
      "utc_offset": String(
        format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60),
      "is_daylight_saving_time": zone.isDaylightSavingTime(for: now),
    ]
  }

  /// Accepts IANA identifiers, abbreviations like EST, and plain city names like "New York".
  private static func resolve(_ name: String?) -> TimeZone? {
    guard let raw = name?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return .current }
    if let zone = TimeZone(identifier: raw) ?? TimeZone(abbreviation: raw.uppercased()) { return zone }
    let city = "/" + raw.replacingOccurrences(of: " ", with: "_").lowercased()
    return TimeZone.knownTimeZoneIdentifiers
      .first { $0.lowercased().hasSuffix(city) }
      .flatMap(TimeZone.init(identifier:))
  }
}
