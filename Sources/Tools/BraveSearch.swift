import Foundation

/// A search result, both as the model sees it and as it's listed under the reply. Results are
/// numbered in order so the model's [1], [2] citations line up with the Sources list.
struct WebSource: Codable, Hashable, Sendable {
  var title: String
  var url: URL
  var snippet: String
  /// "info box" or "direct answer" for Brave's summary results; nil for an ordinary web page.
  var kind: String?
  /// How recent the page is, as Brave reports it (for example "8 hours ago").
  var age: String?
}

struct WebSearchConfig: Sendable {
  let apiKey: String
  let resultCount: Int
}

enum WebSearchError: LocalizedError {
  case http(Int)

  var errorDescription: String? {
    switch self {
    case .http(401), .http(403), .http(422):
      "Brave rejected the API key this build was compiled with."
    case .http(429):
      "Brave Search's rate or usage limit was reached. Try again later."
    case .http(let code):
      "Brave Search returned an error (HTTP \(code))."
    }
  }
}

/// Brave Search API client.
///
/// One of the app's two pieces of networking, and it runs only when web search is on and the model
/// asks for a search. What leaves the phone is the query the model wrote, and nothing else.
enum BraveSearch {
  private static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!
  /// Longest snippet given to the model per result, to leave room in the context for the chat.
  private static let maxSnippetLength = 500
  /// Brave can return many direct answers; the first couple are the relevant ones.
  private static let maxDirectAnswers = 2

  /// No cookies, no cache, no stored credentials.
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 15
    return URLSession(configuration: configuration)
  }()

  /// Returns Brave's info box and direct answers, when it has them, ahead of the web results.
  static func search(_ query: String, config: WebSearchConfig) async throws -> [WebSource] {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "count", value: String(config.resultCount)),
      URLQueryItem(name: "extra_snippets", value: "true"),
    ]
    var request = URLRequest(url: components.url!)
    request.setValue(config.apiKey, forHTTPHeaderField: "X-Subscription-Token")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw WebSearchError.http(status) }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    // Sections are decoded separately so an unexpected shape in an optional one can't hide the rest.
    let web = try decoder.decode(WebResponse.self, from: data).web?.results ?? []
    let infobox = (try? decoder.decode(InfoboxResponse.self, from: data))?.infobox?.results ?? []
    let faq = (try? decoder.decode(FAQResponse.self, from: data))?.faq?.results ?? []

    let infoboxSources = infobox.prefix(1).compactMap { result -> WebSource? in
      guard let title = result.title, let url = result.url.flatMap(URL.init(string:)) else { return nil }
      let text = [result.description, result.longDesc].compactMap { $0 }.joined(separator: ". ")
      return source(title: title, url: url, text: text, kind: "info box")
    }
    let answerSources = faq.prefix(maxDirectAnswers).compactMap { result -> WebSource? in
      guard let url = result.url.flatMap(URL.init(string:)) else { return nil }
      return source(
        title: result.question, url: url, text: "Q: \(result.question) A: \(result.answer)",
        kind: "direct answer")
    }
    let webSources = web.compactMap { result -> WebSource? in
      guard let url = URL(string: result.url) else { return nil }
      let text = ([result.description] + (result.extraSnippets ?? [])).compactMap { $0 }
        .joined(separator: " ")
      return source(title: result.title, url: url, text: text, kind: nil, age: result.age)
    }
    return infoboxSources + answerSources + webSources
  }

  private static func source(
    title: String, url: URL, text: String, kind: String?, age: String? = nil
  ) -> WebSource {
    WebSource(
      title: plainText(title), url: url, snippet: String(plainText(text).prefix(maxSnippetLength)),
      kind: kind, age: age)
  }

  /// Brave highlights matches with HTML tags and escapes some characters.
  private static func plainText(_ html: String) -> String {
    var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities = [
      "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ",
      "&amp;": "&",
    ]
    for (entity, character) in entities {
      text = text.replacingOccurrences(of: entity, with: character)
    }
    return text
  }

  private struct Section<Item: Decodable>: Decodable {
    let results: [Item]
  }

  private struct WebResponse: Decodable {
    struct Result: Decodable {
      let title: String
      let url: String
      let description: String?
      let extraSnippets: [String]?
      let age: String?
    }

    let web: Section<Result>?
  }

  private struct FAQResponse: Decodable {
    struct Result: Decodable {
      let question: String
      let answer: String
      let url: String?
    }

    let faq: Section<Result>?
  }

  private struct InfoboxResponse: Decodable {
    struct Result: Decodable {
      let title: String?
      let url: String?
      let description: String?
      let longDesc: String?
    }

    let infobox: Section<Result>?
  }
}
