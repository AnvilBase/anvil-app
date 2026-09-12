import Foundation

/// Hides raw tool-call text from a reply and collects it.
///
/// llama.cpp sometimes streams a tool call as ordinary content instead of in `tool_calls`
/// (llama.cpp issue #22786). Without this the user would see the model's internal call syntax in the
/// middle of its answer, and the call would never run.
struct RawToolCallFilter {
  private static let open = "<|tool_call>"
  private static let close = "<tool_call|>"

  private var buffer = ""
  private var insideCall = false
  private var rawCalls: [String] = []

  /// Takes a streamed piece and returns the part that can be shown now.
  mutating func consume(_ piece: String) -> String {
    buffer += piece
    var visible = ""
    while true {
      if insideCall {
        guard let end = buffer.range(of: Self.close) else { return visible }
        rawCalls.append(String(buffer[..<end.lowerBound]))
        buffer = String(buffer[end.upperBound...])
        insideCall = false
      } else if let start = buffer.range(of: Self.open) {
        visible += buffer[..<start.lowerBound]
        buffer = String(buffer[start.upperBound...])
        insideCall = true
      } else {
        // Hold back what could be the start of "<|tool_call>" split across two chunks.
        let keep = Self.partialOpenLength(at: buffer)
        visible += buffer.dropLast(keep)
        buffer = String(buffer.suffix(keep))
        return visible
      }
    }
  }

  /// Returns whatever text is left, plus the tool calls found along the way.
  mutating func finish() -> (visible: String, calls: [PendingToolCall]) {
    let visible = insideCall ? "" : buffer
    if insideCall { rawCalls.append(buffer) }
    buffer = ""
    insideCall = false
    return (visible, rawCalls.compactMap(GemmaToolCall.parse))
  }

  private static func partialOpenLength(at text: String) -> Int {
    for length in stride(from: min(open.count - 1, text.count), to: 0, by: -1)
    where open.hasPrefix(text.suffix(length)) {
      return length
    }
    return 0
  }
}

/// Parses Gemma's tool-call syntax, `call:get_weather{location:<|"|>Paris<|"|>}`, into a name and
/// JSON arguments. Keys are bare and strings are wrapped in `<|"|>`.
enum GemmaToolCall {
  private static let quote = "<|\"|>"

  static func parse(_ raw: String) -> PendingToolCall? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("call:"), let brace = text.firstIndex(of: "{") else { return nil }
    let name = text[text.index(text.startIndex, offsetBy: 5)..<brace]
      .trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, let json = jsonText(from: text[brace...]),
      (try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil
    else { return nil }
    return PendingToolCall(id: "", name: name, arguments: json)
  }

  private static func jsonText(from source: Substring) -> String? {
    var output = ""
    var rest = source
    while let first = rest.first {
      if rest.hasPrefix(quote) {
        rest = rest.dropFirst(quote.count)
        guard let end = rest.range(of: quote) else { return nil }
        output += jsonString(String(rest[..<end.lowerBound]))
        rest = rest[end.upperBound...]
      } else if first.isLetter || first == "_" {
        let word = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        rest = rest.dropFirst(word.count)
        // A word followed by ":" is a key; otherwise it's true, false, or null.
        output += rest.first == ":" ? jsonString(String(word)) : String(word)
      } else {
        output.append(first)
        rest = rest.dropFirst()
      }
    }
    return output
  }

  private static func jsonString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
      let array = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return String(array.dropFirst().dropLast())
  }
}
