import Foundation
import LiteRTLM

/// What a tool needs before the model is allowed to call it.
enum ToolRequirement: Sendable {
  /// Always available, including offline.
  case always
  /// Only when web search is on for this reply.
  case webSearch
  /// Only when memory is on.
  case memory
  /// Only with Anvil Dream installed and Anvil Pro active.
  case imageGeneration

  var label: String {
    switch self {
    case .always: "Always available"
    case .webSearch: "When web search is on"
    case .memory: "When memory is on"
    case .imageGeneration: "When Anvil Dream is installed and Pro is active"
    }
  }
}

/// One tool the model can call, described once so it can be both handed to a model and listed on the
/// developer screen.
struct ToolEntry: Identifiable, Sendable {
  var id: String { name }

  /// The name the model calls, such as `web_search`.
  let name: String
  /// One line, for people rather than for the model.
  let summary: String
  let requirement: ToolRequirement
  /// True for tools that exist only in the development app.
  let isDevelopmentOnly: Bool
  let make: @Sendable () -> any Tool

  init(
    name: String, summary: String, requirement: ToolRequirement = .always,
    isDevelopmentOnly: Bool = false, make: @escaping @Sendable () -> any Tool
  ) {
    self.name = name
    self.summary = summary
    self.requirement = requirement
    self.isDevelopmentOnly = isDevelopmentOnly
    self.make = make
  }
}

/// The one place tools are declared.
///
/// The engine asks for its tools here, so what the model can call is described in exactly one
/// place, and a tool is added by writing it and naming it — nothing else changes.
///
/// **Adding a tool to the development app only.** Write it next to the others in `Sources/Tools`,
/// then add an entry inside the `#if ANVIL_DEV` block below with `isDevelopmentOnly: true`. The
/// public app won't know it exists. Promoting it later means moving that one line up into
/// `shared` — no other file changes.
enum ToolRegistry {
  /// Tools both apps ship.
  private static let shared: [ToolEntry] = [
    ToolEntry(
      name: CurrentTimeTool.name,
      summary: "Reads this iPhone's clock, for any time zone. Works offline.",
      make: { CurrentTimeTool() }),
    ToolEntry(
      name: SaveMemoryTool.name,
      summary: "Saves a lasting fact about you, stored only on this iPhone.",
      requirement: .memory,
      make: { SaveMemoryTool() }),
    ToolEntry(
      name: WebSearchTool.name,
      summary: "Searches the web with Brave. The only tool that uses the network.",
      requirement: .webSearch,
      make: { WebSearchTool() }),
    ToolEntry(
      name: GenerateImageTool.name,
      summary: "Makes a picture with Anvil Dream, on this iPhone. Part of Anvil Pro.",
      requirement: .imageGeneration,
      make: { GenerateImageTool() }),
  ]

  /// Tools the development app has and the public app doesn't. Empty on purpose: the two apps are
  /// the same today, and this is where they start to differ.
  private static let developmentOnly: [ToolEntry] = []

  /// Every tool this build knows about, whether or not it's available right now.
  static var catalog: [ToolEntry] {
    #if ANVIL_DEV
      return shared + developmentOnly
    #else
      return shared
    #endif
  }

  /// The tools a conversation with these options gets.
  static func tools(for options: ConversationOptions) -> [any Tool] {
    catalog.filter { isAvailable($0, with: options) }.map { $0.make() }
  }

  static func isAvailable(_ entry: ToolEntry, with options: ConversationOptions) -> Bool {
    switch entry.requirement {
    case .always: true
    case .webSearch: options.webSearch
    case .memory: options.memoryEnabled
    case .imageGeneration: options.imageGeneration
    }
  }
}
