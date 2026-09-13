import Foundation

/// Measurements for one reply. Token counts and speeds come from whichever engine produced it, and
/// are nil when it didn't report them.
struct ReplyStats: Codable, Hashable, Sendable {
  /// "GPU" or "CPU".
  var producedBy: String
  var promptTokens: Int?
  var replyTokens: Int?
  var prefillTokensPerSecond: Double?
  var decodeTokensPerSecond: Double?
  /// Wall-clock time from sending to the first streamed piece of the reply.
  var timeToFirstToken: Double?
  var totalSeconds: Double
  /// Tokens held by the conversation after this reply (system prompt + history + reply).
  var contextTokens: Int?
  var contextLimit: Int
  var peakMemoryBytes: UInt64?
  var peakCPUPercent: Double?
  var gpuMemoryBytes: UInt64?
  var thermalState: String
  var wasStopped: Bool
}

struct ChatMessage: Identifiable, Codable, Sendable {
  enum Role: String, Codable, Sendable {
    case user
    case assistant
  }

  var id = UUID()
  let role: Role
  var text: String
  /// The photo is stored next to the chat as `<id>.jpg`. For a reply, the picture Anvil Dream made.
  var hasImage = false
  /// What a reply's picture was made from, once Anvil Dream has been asked for one.
  var imagePrompt: String?
  var isError = false
  var createdAt = Date()
  var stats: ReplyStats?
  /// Queries the model sent to web search while writing this reply.
  var searchQueries: [String]?
  /// Web results the model received, numbered in order for citations.
  var sources: [WebSource]?
  /// Facts the model saved to memory while writing this reply.
  var savedMemories: [String]?
}

struct Chat: Identifiable, Codable, Sendable {
  var id = UUID()
  var title = ""
  var createdAt = Date()
  var updatedAt = Date()
  /// The system prompt this chat was started with.
  var systemPrompt: String
  var messages: [ChatMessage] = []

  var displayTitle: String { title.isEmpty ? "New chat" : title }
}

/// Running totals across every reply. Kept apart from the chats themselves so they survive deletion.
struct UsageTotals: Codable, Sendable {
  var since = Date()
  var replies = 0
  var promptTokens = 0
  var replyTokens = 0
  var timedReplies = 0
  var timeToFirstTokenSum = 0.0
  var decodedTokens = 0
  var decodeSeconds = 0.0

  mutating func add(_ stats: ReplyStats) {
    replies += 1
    promptTokens += stats.promptTokens ?? 0
    replyTokens += stats.replyTokens ?? 0
    if let firstToken = stats.timeToFirstToken {
      timedReplies += 1
      timeToFirstTokenSum += firstToken
    }
    if let tokens = stats.replyTokens, let rate = stats.decodeTokensPerSecond, rate > 0 {
      decodedTokens += tokens
      decodeSeconds += Double(tokens) / rate
    }
  }

  var averageDecodeSpeed: Double? {
    decodeSeconds > 0 ? Double(decodedTokens) / decodeSeconds : nil
  }

  var averageTimeToFirstToken: Double? {
    timedReplies > 0 ? timeToFirstTokenSum / Double(timedReplies) : nil
  }
}
