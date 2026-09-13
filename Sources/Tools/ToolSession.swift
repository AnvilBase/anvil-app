import Foundation

/// Connects a tool run to the reply that is streaming.
///
/// The engine creates tools itself, from the model's arguments, so a tool can't be handed anything
/// when it's built. It reaches the web search key, Anvil Dream, and the reply's event stream
/// through this shared session instead. One reply is in flight at a time, which is what makes a single shared value safe.
final class ToolSession: @unchecked Sendable {
  static let shared = ToolSession()

  private let lock = NSLock()
  private var webSearchConfig: WebSearchConfig?
  private var generator: (@Sendable (String) async throws -> Data)?
  private var unavailability: ImageUnavailability?
  private var eventHandler: (@Sendable (ReplyEvent) -> Void)?
  private var sourceCount = 0

  func begin(
    webSearch: WebSearchConfig?, imageGenerator: (@Sendable (String) async throws -> Data)?,
    imageUnavailability: ImageUnavailability? = nil,
    onEvent: @escaping @Sendable (ReplyEvent) -> Void
  ) {
    lock.withLock {
      webSearchConfig = webSearch
      generator = imageGenerator
      unavailability = imageUnavailability
      eventHandler = onEvent
      sourceCount = 0
    }
  }

  func end() {
    lock.withLock {
      webSearchConfig = nil
      generator = nil
      unavailability = nil
      eventHandler = nil
    }
  }

  /// The key and settings for searches during this reply; nil when web search is off.
  var webSearch: WebSearchConfig? {
    lock.withLock { webSearchConfig }
  }

  /// Makes a picture from a prompt with Anvil Dream, as JPEG data; nil when it can't be used for
  /// this reply.
  var imageGenerator: (@Sendable (String) async throws -> Data)? {
    lock.withLock { generator }
  }

  /// Why there is no generator for this reply, when there isn't one.
  var imageUnavailability: ImageUnavailability? {
    lock.withLock { unavailability }
  }

  /// Reports tool activity — a search, its sources, a saved memory — to the reply on screen.
  func send(_ event: ReplyEvent) {
    let handler = lock.withLock { eventHandler }
    handler?(event)
  }

  /// Returns the citation number for the first of `count` new search results in this reply.
  func reserveSourceNumbers(_ count: Int) -> Int {
    lock.withLock {
      let first = sourceCount + 1
      sourceCount += count
      return first
    }
  }
}
