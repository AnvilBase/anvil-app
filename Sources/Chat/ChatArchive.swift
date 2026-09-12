import Foundation

/// Saves chats as `Chats/<chat id>/chat.json`, with one JPEG per attached photo beside it, and keeps
/// the usage totals in `Metrics/usage.json`. An actor, so file work stays off the main thread.
actor ChatArchive {
  private let fileManager = FileManager.default

  func loadAll() -> [Chat] {
    guard let root = try? PrivateFiles.directory("Chats"),
      let folders = try? fileManager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    else { return [] }

    return folders
      .compactMap { PrivateFiles.readJSON(Chat.self, from: $0.appendingPathComponent("chat.json")) }
      .map(Self.droppingUnfinishedReplies)
      .filter { !$0.messages.isEmpty }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  func save(_ chat: Chat) throws {
    try PrivateFiles.writeJSON(chat, to: folder(for: chat.id).appendingPathComponent("chat.json"))
  }

  func saveImage(_ data: Data, chatID: UUID, messageID: UUID) throws {
    try PrivateFiles.write(data, to: folder(for: chatID).appendingPathComponent(imageName(messageID)))
  }

  func loadImage(chatID: UUID, messageID: UUID) -> Data? {
    guard let url = imageURL(chatID: chatID, messageID: messageID) else { return nil }
    return try? Data(contentsOf: url)
  }

  func deleteImage(chatID: UUID, messageID: UUID) {
    guard let url = imageURL(chatID: chatID, messageID: messageID) else { return }
    try? fileManager.removeItem(at: url)
  }

  func delete(_ id: UUID) throws {
    let folder = try PrivateFiles.directory("Chats").appendingPathComponent(id.uuidString)
    if fileManager.fileExists(atPath: folder.path) {
      try fileManager.removeItem(at: folder)
    }
  }

  func deleteAll() throws {
    let root = try PrivateFiles.directory("Chats")
    for folder in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      try fileManager.removeItem(at: folder)
    }
  }

  /// Deletes chats with no activity in the last `days` days (0 keeps everything). Returns their IDs.
  func purge(olderThanDays days: Int, now: Date = Date()) -> [UUID] {
    guard days > 0 else { return [] }
    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    return loadAll().filter { $0.updatedAt < cutoff }.compactMap { chat in
      (try? delete(chat.id)).map { chat.id }
    }
  }

  func loadTotals() -> UsageTotals {
    guard let folder = try? PrivateFiles.directory("Metrics") else { return UsageTotals() }
    return PrivateFiles.readJSON(UsageTotals.self, from: folder.appendingPathComponent("usage.json"))
      ?? UsageTotals()
  }

  func saveTotals(_ totals: UsageTotals) throws {
    try PrivateFiles.writeJSON(
      totals, to: PrivateFiles.directory("Metrics").appendingPathComponent("usage.json"))
  }

  private func folder(for id: UUID) throws -> URL {
    let folder = try PrivateFiles.directory("Chats")
      .appendingPathComponent(id.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func imageURL(chatID: UUID, messageID: UUID) -> URL? {
    try? PrivateFiles.directory("Chats")
      .appendingPathComponent(chatID.uuidString, isDirectory: true)
      .appendingPathComponent(imageName(messageID))
  }

  private func imageName(_ messageID: UUID) -> String { "\(messageID.uuidString).jpg" }

  /// A reply left empty because the app quit mid-generation carries no information.
  private static func droppingUnfinishedReplies(_ chat: Chat) -> Chat {
    var chat = chat
    chat.messages.removeAll {
      $0.role == .assistant && $0.text.isEmpty && $0.thinking.isEmpty && $0.stats == nil
    }
    return chat
  }
}
