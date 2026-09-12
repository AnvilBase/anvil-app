import Foundation
import Observation

struct MemoryItem: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var text: String
  var createdAt = Date()
}

/// Facts remembered across chats.
///
/// Stored only on this iPhone, with the same protection as chat history: unreadable while the phone
/// is locked, and excluded from backups. Nothing here is ever uploaded.
@MainActor
@Observable
final class MemoryStore {
  /// Newest first.
  private(set) var items: [MemoryItem] = []

  /// The most memory text given to the model, so a long list can't crowd out the chat itself.
  static let promptCharacterLimit = 1_500

  init() {
    items = Self.load()
  }

  /// Adds a memory unless the same text is already saved.
  func add(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      !items.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame })
    else { return }
    items.insert(MemoryItem(text: trimmed), at: 0)
    save()
  }

  func delete(at offsets: IndexSet) {
    for index in offsets.sorted(by: >) {
      items.remove(at: index)
    }
    save()
  }

  func deleteAll() {
    items = []
    save()
  }

  /// The memories handed to the model: newest first, within the character limit.
  var promptItems: [String] {
    var remaining = Self.promptCharacterLimit
    var result: [String] = []
    for item in items {
      remaining -= item.text.count
      if remaining < 0 { break }
      result.append(item.text)
    }
    return result
  }

  private func save() {
    // A failed write (for example, while the phone is locked) is retried on the next change.
    try? PrivateFiles.writeJSON(items, to: Self.fileURL())
  }

  private static func fileURL() throws -> URL {
    try PrivateFiles.directory("Memory").appendingPathComponent("memories.json")
  }

  private static func load() -> [MemoryItem] {
    guard let url = try? fileURL() else { return [] }
    return PrivateFiles.readJSON([MemoryItem].self, from: url) ?? []
  }
}
