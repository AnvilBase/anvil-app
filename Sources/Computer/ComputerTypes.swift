import Foundation
import Security

/// Where a reply is generated.
enum ReplyLocation: String, Codable, CaseIterable, Identifiable, Sendable {
  case iPhone
  case computer
  case automatic

  var id: Self { self }

  var label: String {
    switch self {
    case .iPhone: "iPhone"
    case .computer: "My computer"
    case .automatic: "Automatic"
    }
  }

  /// Explains the choice in Settings.
  var detail: String {
    switch self {
    case .iPhone: "Every reply runs on this iPhone."
    case .computer: "Every reply runs on your computer."
    case .automatic: "Your computer when it answers quickly, this iPhone otherwise."
    }
  }
}

enum ComputerAddress {
  /// The computer's HTTPS base URL, as printed by `tailscale serve`. A bare host name gets an
  /// https:// prefix; anything that isn't HTTPS is refused, because the token travels with it.
  static func url(from text: String) -> URL? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if !trimmed.contains("://") { trimmed = "https://" + trimmed }
    guard let url = URL(string: trimmed), url.scheme == "https", url.host() != nil else { return nil }
    return url
  }
}

/// The access token for the companion server, kept in this iPhone's Keychain: readable only while
/// the phone is unlocked, never synced to other devices, and namespaced per app so the public and
/// development apps can point at different computers.
enum ComputerTokenStore {
  private static let service = "\(AppFlavor.storageNamespace).ComputerAccessToken"

  static func read() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  static func save(_ token: String) -> Bool {
    delete()
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecValueData as String: Data(token.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  static func delete() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

/// What the computer reports about its model: from the companion server's `/status`, or from
/// llama-server's `/props` when you point the app straight at llama-server.
struct ComputerStatus: Equatable, Sendable {
  var model: String
  var context: Int?
  var vision: Bool?
  var busy: Bool?
  var modelServer: String?
  var companionVersion: String?

  var isReady: Bool { modelServer == nil || modelServer == "ready" }

  var summary: String {
    var parts = [model]
    if let context { parts.append("\(context.formatted()) context") }
    if let vision { parts.append(vision ? "photos on" : "photos off") }
    if let busy, busy { parts.append("busy") }
    parts.append(companionVersion.map { "companion server \($0)" } ?? "llama-server directly")
    return parts.joined(separator: " · ")
  }
}

/// Whether your computer can be reached, for the toolbar dot and for Automatic routing.
enum ComputerState: Equatable, Sendable {
  /// Replies run only on this iPhone.
  case notUsed
  case notConfigured
  case checking
  case online(ComputerStatus)
  case unreachable(String)

  var label: String {
    switch self {
    case .notUsed: "Not used"
    case .notConfigured: "Not set up. Add the address in Settings › My computer."
    case .checking: "Checking…"
    case .online(let status): "Connected · \(status.summary)"
    case .unreachable(let reason): "Not reachable. \(reason)"
    }
  }
}

enum ComputerError: LocalizedError {
  case notConfigured
  case offline
  case unauthorized
  case notReady(String)
  case unreachable(String)
  case http(Int)
  case server(String)
  case tooManyToolRounds

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      "Add your computer's address in Settings › My computer."
    case .offline:
      "This iPhone is offline, so it can't reach your computer."
    case .unauthorized:
      "Your computer needs its access token. Print it on the computer with the companion server's "
        + "show-token command, then enter it in Settings › My computer."
    case .notReady(let state):
      "The model on your computer isn't ready yet (\(state))."
    case .unreachable(let detail):
      "Couldn't reach your computer. Make sure Tailscale is on, on this iPhone and the computer. "
        + "(\(detail))"
    case .http(let code):
      "Your computer returned an error (HTTP \(code))."
    case .server(let message):
      "Your computer reported an error: \(message)"
    case .tooManyToolRounds:
      "The model kept calling tools without answering."
    }
  }
}

/// Token counts and speeds from llama.cpp's `timings` in the final streamed chunk.
struct ReplyTimings: Sendable {
  var promptTokens: Int?
  var replyTokens: Int?
  var prefillTokensPerSecond: Double?
  var decodeTokensPerSecond: Double?
}
