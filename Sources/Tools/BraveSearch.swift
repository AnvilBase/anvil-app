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
  /// Who is asked. The app is open source, so it carries no key of its own: searches go to
  /// anvilai.com, which holds one and passes Brave's answer back unchanged. A key compiled into a
  /// build — a developer's own, in `Config/Local.xcconfig` — sends the same request to Brave
  /// directly.
  enum Route: Sendable {
    case anvil
    case brave(apiKey: String)
  }

  let route: Route
  let resultCount: Int

  /// Brave directly when the build has a key, anvilai.com otherwise.
  init(apiKey: String, resultCount: Int) {
    route = apiKey.isEmpty ? .anvil : .brave(apiKey: apiKey)
    self.resultCount = resultCount
  }
}

enum WebSearchError: LocalizedError {
  case http(Int)

  var errorDescription: String? {
    switch self {
    case .http(401), .http(403), .http(422):
      "Brave rejected the API key this build was compiled with."
    case .http(429):
      "Web search's rate or usage limit was reached. Try again later."
    case .http(503):
      "Web search isn't set up on the server this build uses."
    case .http(let code):
      "Web search returned an error (HTTP \(code))."
    }
  }
}

/// Brave Search client.
///
/// One of the app's three pieces of networking, and it runs only when web search is on and the model
/// asks for a search. What leaves the phone is the query the model wrote, and nothing else — by way
/// of anvilai.com, or straight to Brave when the build carries its own key. Either way the body that
/// comes back is Brave's, so there is one parser.
enum BraveSearch {
  private static let braveEndpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!
  private static let anvilEndpoint = AnvilServer.url("/api/search")
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
    let request = try request(for: query, config: config)
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

  /// The relay takes the query in a POST body rather than the URL, so it never lands in a request
  /// log; Brave takes it the way Brave takes it.
  private static func request(for query: String, config: WebSearchConfig) throws -> URLRequest {
    var request: URLRequest
    switch config.route {
    case .anvil:
      request = URLRequest(url: anvilEndpoint)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(
        withJSONObject: ["q": query, "count": config.resultCount])
    case .brave(let apiKey):
      var components = URLComponents(url: braveEndpoint, resolvingAgainstBaseURL: false)!
      components.queryItems = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "count", value: String(config.resultCount)),
        URLQueryItem(name: "extra_snippets", value: "true"),
      ]
      request = URLRequest(url: components.url!)
      request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
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
