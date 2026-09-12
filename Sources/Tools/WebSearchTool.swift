import Foundation
import LiteRTLM

/// The model's way to search the web. It decides when to call this; the app never searches on its own.
struct WebSearchTool: Tool {
  static let name = "web_search"
  static let description =
    "Search the web for recent events, current information, or facts you aren't sure about. Returns "
    + "numbered results: Brave's info box and direct answers when available, then web pages with "
    + "snippets and how recent they are."

  @ToolParam(description: "The search query, phrased like a search engine query.")
  var query: String

  func run() async throws -> Any {
    let session = ToolSession.shared
    guard let config = session.webSearch else {
      return ["error": "Web search is turned off."]
    }
    session.send(.searching(query))
    do {
      let results = try await BraveSearch.search(query, config: config)
      session.send(.sources(results))
      guard !results.isEmpty else {
        return ["query": query, "results": [String](), "note": "No results found."]
      }
      // Numbering continues across several searches in one reply, so citations stay unique.
      let first = session.reserveSourceNumbers(results.count)
      let items: [[String: Any]] = results.enumerated().map { offset, source in
        var item: [String: Any] = [
          "number": first + offset,
          "type": source.kind ?? "web page",
          "title": source.title,
          "url": source.url.absoluteString,
          "content": source.snippet,
        ]
        if let age = source.age { item["published"] = age }
        return item
      }
      return ["query": query, "results": items]
    } catch {
      // Handing the error back lets the model tell the user, instead of ending the reply in an error.
      session.send(.searchError(error.localizedDescription))
      return ["error": error.localizedDescription]
    }
  }
}
