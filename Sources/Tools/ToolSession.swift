import Foundation

/// Connects a tool run to the reply that is streaming.
///
/// The engine creates tools itself, from the model's arguments, so a tool can't be handed anything
/// when it's built. It reaches the web search key and the reply's event stream through this shared
/// session instead. One reply is in flight at a time, which is what makes a single shared value safe.
final class ToolSession: @unchecked Sendable {
  static let shared = ToolSession()

  private let lock = NSLock()
  private var webSearchConfig: WebSearchConfig?
  private var eventHandler: (@Sendable (ReplyEvent) -> Void)?
  private var sourceCount = 0

  func begin(webSearch: WebSearchConfig?, onEvent: @escaping @Sendable (ReplyEvent) -> Void) {
    lock.withLock {
      webSearchConfig = webSearch
      eventHandler = onEvent
      sourceCount = 0
    }
  }

  func end() {
    lock.withLock {
      webSearchConfig = nil
      eventHandler = nil
    }
  }

  /// The key and settings for searches during this reply; nil when web search is off.
  var webSearch: WebSearchConfig? {
    lock.withLock { webSearchConfig }
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
