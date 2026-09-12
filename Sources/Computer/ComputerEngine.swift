import Foundation
import LiteRTLM

struct ComputerRequest: Sendable {
  let options: ConversationOptions
  let history: [HistoryTurn]
  let prompt: String
  let imageJPEG: Data?
  let sampler: SamplerValues?
  let maxTokens: Int?
  let thinking: Bool
  let webSearch: WebSearchConfig?
}

enum ComputerEvent: Sendable {
  case reply(ReplyEvent)
  case timings(ReplyTimings)
}

/// A tool call being assembled from streamed pieces.
struct PendingToolCall: Sendable {
  var id: String
  var name: String
  /// JSON text.
  var arguments: String
}

/// Streams replies from the bigger model on your computer.
///
/// It talks to a companion server (or, for a quick test, llama-server itself) reachable over your
/// private Tailscale network, using the OpenAI chat-completions format. Tools still run on the
/// iPhone: the model asks for a search, the phone performs it, and the result goes back in a
/// follow-up request. Apart from web search this is the app's only networking, and it only ever
/// contacts the address in Settings › My computer.
enum ComputerEngine {
  /// How many times the model may call tools before it has to answer.
  private static let maxToolRounds = 6

  /// No cookies, cache, or stored credentials.
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    // Leaves room for a slow first token when the computer is busy or reading a long prompt.
    configuration.timeoutIntervalForRequest = 120
    return URLSession(configuration: configuration)
  }()

  /// Asks the computer what it's running. Falls back to llama-server's own `/props` when there's no
  /// companion server in front of it.
  static func status(baseURL: URL, token: String?, timeout: TimeInterval) async throws -> ComputerStatus {
    do {
      let json = try await getJSON(
        baseURL.appendingPathComponent("status"), token: token, timeout: timeout)
      // Two spellings for the same two fields: `llama_server` / `foundry_version` are what the
      // reference companion server reports, and the generic names are for anything else.
      return ComputerStatus(
        model: json["model"] as? String ?? "Unknown model",
        context: json["context"] as? Int,
        vision: json["vision"] as? Bool,
        busy: json["busy"] as? Bool,
        modelServer: json["llama_server"] as? String ?? json["model_server"] as? String,
        companionVersion: json["foundry_version"] as? String ?? json["server_version"] as? String)
    } catch ComputerError.http(404) {
      let props = try await getJSON(
        baseURL.appendingPathComponent("props"), token: token, timeout: timeout)
      let generation = props["default_generation_settings"] as? [String: Any]
      let modalities = props["modalities"] as? [String: Any]
      let modelFile = (props["model_path"] as? String)?
        .split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
      return ComputerStatus(
        model: modelFile ?? "llama-server",
        context: generation?["n_ctx"] as? Int,
        vision: modalities?["vision"] as? Bool,
        busy: nil,
        modelServer: "ready",
        companionVersion: nil)
    }
  }

  static func stream(
    _ request: ComputerRequest, baseURL: URL, token: String?
  ) -> AsyncThrowingStream<ComputerEvent, Error> {
    AsyncThrowingStream { continuation in
      ToolSession.shared.begin(webSearch: request.webSearch) { event in
        continuation.yield(.reply(event))
      }
      let task = Task {
        defer { ToolSession.shared.end() }
        do {
          try await run(request, baseURL: baseURL, token: token, continuation: continuation)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// One reply, including as many tool rounds as the model asks for.
  private static func run(
    _ request: ComputerRequest, baseURL: URL, token: String?,
    continuation: AsyncThrowingStream<ComputerEvent, Error>.Continuation
  ) async throws {
    let tools = ToolRegistry.tools(for: request.options)
    let toolManager = ToolManager(tools: tools)

    var messages: [[String: Any]] = [
      ["role": "system", "content": PromptBuilder.systemPrompt(for: request.options)]
    ]
    for turn in request.history where !turn.text.isEmpty {
      messages.append(["role": turn.isUser ? "user" : "assistant", "content": turn.text])
    }
    if let image = request.imageJPEG {
      let parts: [[String: Any]] = [
        [
          "type": "image_url",
          "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"],
        ],
        ["type": "text", "text": request.prompt],
      ]
      messages.append(["role": "user", "content": parts])
    } else {
      messages.append(["role": "user", "content": request.prompt])
    }

    var body: [String: Any] = [
      "stream": true,
      "tools": tools.map { $0.getSchema() },
      "chat_template_kwargs": ["enable_thinking": request.thinking],
    ]
    if let sampler = request.sampler {
      body["temperature"] = sampler.temperature
      body["top_p"] = sampler.topP
      body["top_k"] = sampler.topK
    }
    if let maxTokens = request.maxTokens { body["max_tokens"] = maxTokens }

    for _ in 0..<maxToolRounds {
      body["messages"] = messages
      let calls = try await streamOnce(
        body: body, baseURL: baseURL, token: token, continuation: continuation)
      guard !calls.isEmpty else { return }

      messages.append([
        "role": "assistant",
        "content": "",
        "tool_calls": calls.map { call in
          [
            "id": call.id, "type": "function",
            "function": ["name": call.name, "arguments": call.arguments],
          ]
        },
      ])
      for call in calls {
        let arguments =
          (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        let result: Any
        do {
          result = try await toolManager.execute(name: call.name, arguments: arguments)
        } catch {
          result = ["error": error.localizedDescription]
        }
        messages.append([
          "role": "tool", "tool_call_id": call.id, "name": call.name, "content": jsonText(result),
        ])
      }
    }
    throw ComputerError.tooManyToolRounds
  }

  /// Sends one request and relays the streamed reply. Returns the tool calls the model made, if any.
  private static func streamOnce(
    body: [String: Any], baseURL: URL, token: String?,
    continuation: AsyncThrowingStream<ComputerEvent, Error>.Continuation
  ) async throws -> [PendingToolCall] {
    var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    authorize(&urlRequest, token: token)
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: urlRequest)
    } catch let error as URLError where error.code != .cancelled {
      throw ComputerError.unreachable(error.localizedDescription)
    }
    try check(response)

    var calls: [Int: PendingToolCall] = [:]
    var rawCalls = RawToolCallFilter()
    for try await line in bytes.lines {
      guard line.hasPrefix("data:") else { continue }
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      if payload == "[DONE]" { break }
      guard let chunk = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
      else { continue }
      if let error = chunk["error"] as? [String: Any] {
        throw ComputerError.server(error["message"] as? String ?? "Unknown error")
      }
      if let timings = chunk["timings"] as? [String: Any] {
        continuation.yield(
          .timings(
            ReplyTimings(
              promptTokens: timings["prompt_n"] as? Int,
              replyTokens: timings["predicted_n"] as? Int,
              prefillTokensPerSecond: timings["prompt_per_second"] as? Double,
              decodeTokensPerSecond: timings["predicted_per_second"] as? Double)))
      }
      guard let choice = (chunk["choices"] as? [[String: Any]])?.first,
        let delta = choice["delta"] as? [String: Any]
      else { continue }

      if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
        continuation.yield(.reply(.thinking(reasoning)))
      }
      if let content = delta["content"] as? String, !content.isEmpty {
        let visible = rawCalls.consume(content)
        if !visible.isEmpty { continuation.yield(.reply(.text(visible))) }
      }
      for item in delta["tool_calls"] as? [[String: Any]] ?? [] {
        let index = item["index"] as? Int ?? 0
        var call = calls[index] ?? PendingToolCall(id: "", name: "", arguments: "")
        if let id = item["id"] as? String, !id.isEmpty { call.id = id }
        if let function = item["function"] as? [String: Any] {
          if let name = function["name"] as? String, call.name.isEmpty { call.name = name }
          if let arguments = function["arguments"] as? String { call.arguments += arguments }
        }
        calls[index] = call
      }
    }

    let leftover = rawCalls.finish()
    if !leftover.visible.isEmpty { continuation.yield(.reply(.text(leftover.visible))) }
    var result =
      calls.sorted { $0.key < $1.key }.map(\.value).filter { !$0.name.isEmpty } + leftover.calls
    for index in result.indices where result[index].id.isEmpty {
      result[index].id = "call_\(UUID().uuidString.prefix(8))"
    }
    return result
  }

  private static func getJSON(_ url: URL, token: String?, timeout: TimeInterval) async throws
    -> [String: Any]
  {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    authorize(&request, token: token)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code != .cancelled {
      throw ComputerError.unreachable(error.localizedDescription)
    }
    try check(response)
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw ComputerError.server("Unexpected response from \(url.path())")
    }
    return json
  }

  private static func check(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw ComputerError.server("Unexpected response.")
    }
    switch http.statusCode {
    case 200..<300: return
    case 401, 403: throw ComputerError.unauthorized
    default: throw ComputerError.http(http.statusCode)
    }
  }

  private static func authorize(_ request: inout URLRequest, token: String?) {
    if let token, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
  }

  private static func jsonText(_ value: Any) -> String {
    if JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value),
      let text = String(data: data, encoding: .utf8)
    {
      return text
    }
    return String(describing: value)
  }
}
