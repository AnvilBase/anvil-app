import Foundation
import LiteRTLM

/// Lets the model remember a lasting fact about you.
///
/// The fact goes straight to `MemoryStore` on this iPhone through the tool session; nothing leaves
/// the device, and the reply shows what was saved.
struct SaveMemoryTool: Tool {
  static let name = "save_memory"
  static let description =
    "Remember a lasting fact about the user for future chats, such as their name, preferences, or "
    + "ongoing projects. Use it when the user asks you to remember something or shares a clearly "
    + "lasting personal detail."

  @ToolParam(
    description: "The fact to remember, as a short statement such as \"The user is vegetarian.\"")
  var fact: String

  func run() async throws -> Any {
    let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ["error": "Nothing to remember."] }
    ToolSession.shared.send(.memorySaved(trimmed))
    return ["saved": trimmed]
  }
}
