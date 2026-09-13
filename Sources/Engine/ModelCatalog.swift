import Foundation

/// What a catalog model is for: text, which the chat runs on, or pictures, which Anvil Dream makes.
enum ModelKind: String, Codable, Sendable {
  case text
  case image
}

/// A model Anvil publishes, as described by https://www.anvilai.com/api/models.
///
/// The file is several gigabytes, so it is served as a list of parts. Each part carries its own
/// SHA-256; the app checks a part before appending it, which is what makes an interrupted download
/// safe to resume.
struct CatalogModel: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let version: String
  let summary: String
  /// How big the model is, the way models are sized: "2B", "4B". Shown after the summary.
  let parameters: String?
  /// What the assembled file is called on the phone, e.g. `anvil-forge.litertlm`. For an image
  /// model it is the archive that is unpacked on arrival, e.g. `anvil-dream.aar`.
  let fileName: String
  /// Text unless the catalog says otherwise: image models arrived later than the schema.
  let kind: ModelKind?
  let sizeBytes: Int64
  let sha256: String
  let parts: [CatalogPart]
  /// Free space to insist on before starting. Absent means "the model, plus a gigabyte".
  let minimumFreeBytes: Int64?
  let recommended: Bool?
  /// Part of Anvil Pro: listed behind the paywall, and downloaded or switched to only while Pro is
  /// active. Absent means free.
  let pro: Bool?
  /// The open model this one is built from, and its licence. Both are shown before downloading.
  let basedOn: String?
  let license: String?
  let licenseURL: URL?
  /// Named in the catalog but not published yet: listed in its place, with nothing to download.
  let comingSoon: Bool?

  var isRecommended: Bool { recommended ?? false }
  /// Nothing to download: the catalog says so, or there are no parts to fetch.
  var isComingSoon: Bool { (comingSoon ?? false) || parts.isEmpty }
  var isPro: Bool { pro ?? false }
  var modelKind: ModelKind { kind ?? .text }
  var isImage: Bool { modelKind == .image }

  var requiredFreeBytes: Int64 { minimumFreeBytes ?? (sizeBytes + 1_000_000_000) }

  var formattedSize: String {
    ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
  }
}

struct CatalogPart: Codable, Hashable, Sendable {
  let name: String
  let sizeBytes: Int64
  let sha256: String
  let url: URL
}

/// Reads the list of models Anvil publishes.
///
/// This is the only request the app makes to anvilai.com, and only from the model screen. The URLs
/// it hands back are on anvilai.com too, so the app never depends on where the files are kept.
enum ModelCatalog {
  private static let fallbackHost = "www.anvilai.com"

  /// Where the catalog lives. The host comes from `ANVIL_MODELS_HOST` in `Config/Shared.xcconfig`
  /// by way of the bundle, so a fork can point the app at its own deployment without touching any
  /// Swift. It is the host alone because an xcconfig treats `//` as the start of a comment.
  static let endpoint: URL = {
    let configured = (Bundle.main.infoDictionary?["ModelCatalogHost"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // An unset build setting can reach the bundle as the literal "$(ANVIL_MODELS_HOST)".
    let host = configured.isEmpty || configured.hasPrefix("$(") ? fallbackHost : configured
    return URL(string: "https://\(host)/api/models")
      ?? URL(string: "https://\(fallbackHost)/api/models")!
  }()

  private struct Response: Decodable {
    let schemaVersion: Int?
    let models: [CatalogModel]
  }

  enum Failure: LocalizedError {
    case badResponse(Int)
    case unreadable

    var errorDescription: String? {
      switch self {
      case .badResponse(let code): "anvilai.com answered with \(code)."
      case .unreadable: "The model list couldn't be read."
      }
    }
  }

  static func load() async throws -> [CatalogModel] {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }

    let (data, response) = try await session.data(from: endpoint)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw Failure.badResponse(http.statusCode)
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data).models
    } catch {
      throw Failure.unreadable
    }
  }
}
