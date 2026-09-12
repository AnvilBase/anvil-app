import Foundation
import Observation

enum EngineBackendPreference: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case gpu
  case cpu

  var id: Self { self }

  var label: String {
    switch self {
    case .automatic: "Automatic (GPU, then CPU)"
    case .gpu: "GPU only"
    case .cpu: "CPU only"
    }
  }
}

/// Whether the app follows the phone or is told which way to look.
enum AppearancePreference: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: Self { self }

  var label: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

/// Settings that only take effect when the engine is reloaded.
struct EngineOptions: Codable, Equatable, Sendable {
  var backend: EngineBackendPreference = .automatic
  /// KV-cache size (input + output tokens). Larger values use more memory.
  var contextSize = 4096
  var imageInput = true
}

struct SamplerValues: Codable, Equatable, Sendable {
  var temperature: Double
  var topK: Int
  var topP: Double
}

struct AppSettings: Codable, Equatable, Sendable {
  static var defaultSystemPrompt: String {
    "You are \(AppFlavor.appName), a helpful assistant running privately on the user's iPhone. "
      + "Answer clearly and concisely."
  }

  static let contextSizes = [2048, 4096, 8192, 16384, 32768]
  static let replyLengthLimits = [0, 256, 512, 1024, 2048, 4096]
  static let retentionChoices = [1, 3, 7, 30, 0]
  static let searchResultCounts = [3, 5, 8]

  /// Used for new chats; each chat keeps the prompt it started with.
  var systemPrompt = AppSettings.defaultSystemPrompt
  var useModelSamplerDefaults = true
  var sampler = SamplerValues(temperature: 1.0, topK: 64, topP: 0.95)
  /// Maximum tokens per reply (thinking included); 0 means no limit.
  var maxReplyTokens = 0
  var thinkingEnabled = false
  var engine = EngineOptions()
  /// Days without activity before a chat is deleted; 0 keeps chats until deleted by hand.
  var historyRetentionDays = 3
  /// On by default. When on (and online, with a key), the model can call the web search tool.
  var webSearchEnabled = true
  var webSearchResultCount = 5
  /// Remember facts across chats (stored only on this iPhone).
  var memoryEnabled = true
  /// Send a dictated message automatically when you pause.
  var autoSendVoice = true
  /// Light, dark, or whatever the phone is set to.
  var appearance = AppearancePreference.system
  /// Asks the development app to present itself as the public one. Meaningless in the public app,
  /// which has no way to be handed it — see `AppFlavor.showsDevelopmentFeatures`.
  var previewAsPublic = false

  init() {}

  /// Keys missing from a file written by an older version keep their defaults, so an update never
  /// resets someone's settings.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = AppSettings()
    func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
      try container.decodeIfPresent(T.self, forKey: key) ?? fallback
    }
    systemPrompt = try value(.systemPrompt, defaults.systemPrompt)
    useModelSamplerDefaults = try value(.useModelSamplerDefaults, defaults.useModelSamplerDefaults)
    sampler = try value(.sampler, defaults.sampler)
    maxReplyTokens = try value(.maxReplyTokens, defaults.maxReplyTokens)
    thinkingEnabled = try value(.thinkingEnabled, defaults.thinkingEnabled)
    engine = try value(.engine, defaults.engine)
    historyRetentionDays = try value(.historyRetentionDays, defaults.historyRetentionDays)
    webSearchEnabled = try value(.webSearchEnabled, defaults.webSearchEnabled)
    webSearchResultCount = try value(.webSearchResultCount, defaults.webSearchResultCount)
    memoryEnabled = try value(.memoryEnabled, defaults.memoryEnabled)
    autoSendVoice = try value(.autoSendVoice, defaults.autoSendVoice)
    appearance = try value(.appearance, defaults.appearance)
    previewAsPublic = try value(.previewAsPublic, defaults.previewAsPublic)
  }
}

/// Holds the settings and writes them to a protected JSON file, the same way chats are stored: the
/// system prompt can be personal.
@MainActor
@Observable
final class SettingsStore {
  var values: AppSettings

  init() {
    values = Self.load() ?? AppSettings()
  }

  func save() {
    // A failed write (for example, while the phone is locked) is retried on the next save.
    try? PrivateFiles.writeJSON(values, to: Self.fileURL())
  }

  private static func fileURL() throws -> URL {
    try PrivateFiles.directory("Settings").appendingPathComponent("settings.json")
  }

  private static func load() -> AppSettings? {
    guard let url = try? fileURL() else { return nil }
    return PrivateFiles.readJSON(AppSettings.self, from: url)
  }
}
