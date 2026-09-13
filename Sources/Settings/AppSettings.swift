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
  /// What the model is told about itself before anything else.
  ///
  /// Anvil's own prompt is proprietary and lives in a private repository, AnvilBase/anvil-prompt.
  /// `Scripts/bootstrap.sh` copies it into `Sources/Prompt/DefaultPrompt.txt`, which this repository
  /// ignores and the synchronised `Sources` folder bundles. A build without the file — anyone's
  /// build of the open-source app — gets the line below, so the app always has a prompt; it just
  /// isn't Anvil's.
  static let defaultSystemPrompt: String = {
    if let url = Bundle.main.url(forResource: "DefaultPrompt", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return "You are \(AppFlavor.productName), a helpful assistant running privately on the user's "
      + "iPhone. Answer clearly and concisely."
  }()

  /// The prompt for voice mode, where replies are read aloud and answered by speaking: the same
  /// Anvil, keeping to a sentence or three. From `Sources/Prompt/VoicePrompt.txt`, which the
  /// bootstrap copies in beside the main prompt, with a short built-in stand-in without it.
  static let voiceSystemPrompt: String = {
    if let url = Bundle.main.url(forResource: "VoicePrompt", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return "You are \(AppFlavor.productName), a helpful assistant running privately on the user's "
      + "iPhone. You are talking with the user out loud: your reply is read to them by a voice. "
      + "Keep every reply to one to three plain sentences, the answer first, with no markdown, "
      + "lists or code."
  }()

  /// The prompt a chat runs on, given what was set for it: the custom prompt when there is one,
  /// and Anvil's own when the setting is empty. Empty is how "the default" is spelled everywhere
  /// the prompt is stored — the settings file, a chat — so the proprietary text is never written
  /// out where it could be read, and Settings can show the word rather than the prompt.
  static func prompt(for custom: String) -> String {
    custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultSystemPrompt : custom
  }

  static let contextSizes = [2048, 4096, 8192, 16384, 32768]
  static let replyLengthLimits = [0, 256, 512, 1024, 2048, 4096]
  static let retentionChoices = [1, 3, 7, 30, 0]
  static let searchResultCounts = [3, 5, 8]

  /// A prompt of your own for new chats, or empty for Anvil's own; each chat keeps the one it
  /// started with. Resolved by `AppSettings.prompt(for:)`, never read straight.
  var systemPrompt = ""
  var useModelSamplerDefaults = true
  var sampler = SamplerValues(temperature: 1.0, topK: 64, topP: 0.95)
  /// Maximum tokens per reply; 0 means no limit.
  var maxReplyTokens = 0
  var engine = EngineOptions()
  /// Days without activity before a chat is deleted; 0, the default, keeps chats until they are
  /// deleted by hand.
  var historyRetentionDays = 0
  /// Off by default: the two things that leave the phone should both be asked for, and this is the
  /// one you can ask for with a button. When on (and online, with a key), the model can call the
  /// web search tool.
  var webSearchEnabled = false
  var webSearchResultCount = 5
  /// Remember facts across chats (stored only on this iPhone).
  var memoryEnabled = true
  /// Send a dictated message automatically when you pause.
  var autoSendVoice = true
  /// Light, dark, or whatever the phone is set to.
  var appearance = AppearancePreference.system
  /// Whether the welcome screen has been shown. It is shown once, on the first launch.
  var hasSeenWelcome = false

  // MARK: - Anvil Pro
  //
  // Stored like everything else, and read like everything else — but only honoured while the App
  // Store says Pro is active (see `ProAccess`). Nothing here unlocks anything.

  /// The look of the app: the page, the bubbles, the one filled button.
  var theme = AppTheme.ink
  /// Which of the app's icons is on the Home Screen.
  var appIcon = AppIconChoice.anvil
  /// The app's own passcode, asked for when the app comes back to the screen. Honoured only while
  /// a passcode is set — see `AppLock`.
  var appLockEnabled = false
  /// Replies read aloud, and the microphone open again when they finish.
  var talkMode = false
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
    // Earlier versions wrote the default prompt itself into the file; that is the default, and
    // the file should say so the short way.
    if systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) == Self.defaultSystemPrompt {
      systemPrompt = ""
    }
    useModelSamplerDefaults = try value(.useModelSamplerDefaults, defaults.useModelSamplerDefaults)
    sampler = try value(.sampler, defaults.sampler)
    maxReplyTokens = try value(.maxReplyTokens, defaults.maxReplyTokens)
    engine = try value(.engine, defaults.engine)
    historyRetentionDays = try value(.historyRetentionDays, defaults.historyRetentionDays)
    webSearchEnabled = try value(.webSearchEnabled, defaults.webSearchEnabled)
    webSearchResultCount = try value(.webSearchResultCount, defaults.webSearchResultCount)
    memoryEnabled = try value(.memoryEnabled, defaults.memoryEnabled)
    autoSendVoice = try value(.autoSendVoice, defaults.autoSendVoice)
    appearance = try value(.appearance, defaults.appearance)
    hasSeenWelcome = try value(.hasSeenWelcome, defaults.hasSeenWelcome)
    theme = try value(.theme, defaults.theme)
    appIcon = try value(.appIcon, defaults.appIcon)
    appLockEnabled = try value(.appLockEnabled, defaults.appLockEnabled)
    talkMode = try value(.talkMode, defaults.talkMode)
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
