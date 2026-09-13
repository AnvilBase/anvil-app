import Foundation

/// Whether a message is asking for a picture to be made.
///
/// Decided here, from the words, rather than left to the model. A small model offered a picture
/// tool reaches for it on messages that never asked — one word is enough — and a paywall that
/// opens on "hi" is a paywall nobody trusts. So the tool is only ever offered where a picture can
/// actually be made, and a message that can't have one is read here first. Sure over sensitive:
/// it takes a verb of making within a few words of a word for a picture — "generate an image",
/// "make me a picture" — or a picture "of" something, and lets everything else through. A message
/// with a photo attached is never asking: "make this image brighter" is about the photo.
enum ImageRequest {
  private static let nouns =
    "(image|images|picture|pictures|photo|photos|photograph|drawing|painting|illustration|sketch"
    + "|artwork|portrait|logo|poster|wallpaper|icon)"
  private static let verbs =
    "(generate|make|create|draw|paint|render|design|produce|sketch|illustrate|imagine|visuali[sz]e"
    + "|show me|give me|send me|get me|need|want)"

  private static let patterns: [NSRegularExpression] = [
    // A verb of making, then a picture within three words: "generate an image", "make me a
    // picture", "I want a photo", "draw a quick sketch".
    try! NSRegularExpression(
      pattern: "\\b\(verbs)\\b(\\s+\\w+){0,3}?\\s+\(nouns)\\b", options: .caseInsensitive),
    // A picture of something: "image of a fox", "a picture showing the sea".
    try! NSRegularExpression(
      pattern: "\\b\(nouns)\\s+(of|showing|depicting)\\b", options: .caseInsensitive),
    // The imperative alone: "draw a fox", "paint the sea at night", "sketch my dog". Draw is
    // the one that has other meanings, so its idioms are let through.
    try! NSRegularExpression(
      pattern: "^\\s*(please\\s+)?((can|could|would|will)\\s+you\\s+)?(please\\s+)?"
        + "(draw|paint|sketch|illustrate|render)\\s+(me\\s+)?"
        + "(?!(an?\\s+|the\\s+)?(conclusion|line|attention|up\\b|on\\b|from\\b|out\\b|back\\b"
        + "|near|closer|breath|inspiration|parallel|comparison|blood|lots|straws))\\S",
      options: .caseInsensitive),
  ]

  static func isAsking(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
  }

  /// The ask at the front of a message — "can you make me a picture of", "generate an image:" —
  /// with the picture's own word kept in it. The word is the ask, and everything after it is
  /// the picture. What the word was still says something: "a painting of mountains" wants a
  /// painting, so a word that names a kind of picture is kept on the end as a style.
  private static let ask = try! NSRegularExpression(
    pattern: "^\\s*(please\\s+)?((can|could|would|will)\\s+you\\s+)?(please\\s+)?"
      + "((generate|make|create|draw|paint|render|design|produce|sketch|illustrate|imagine"
      + "|visuali[sz]e|show|give|send|get|i\\s+want|i\\s+need|i'd\\s+like|i\\s+would\\s+like)"
      + "\\s+(me\\s+)?)?(an?\\s+|the\\s+|some\\s+)?(quick\\s+|new\\s+|nice\\s+|cool\\s+)?"
      + "\(nouns)\\s*(of|showing|depicting|with|for)?\\s*[:\\-–—]?\\s*",
    options: .caseInsensitive)

  /// The imperative ask — "draw me", "can you paint" — which names no picture, only the making
  /// of one. The verb says what kind: a drawing, a painting, a sketch.
  private static let imperative = try! NSRegularExpression(
    pattern: "^\\s*(please\\s+)?((can|could|would|will)\\s+you\\s+)?(please\\s+)?"
      + "(draw|paint|sketch|illustrate|render)\\s+(me\\s+)?",
    options: .caseInsensitive)

  /// What to make, from a message that `isAsking`: the message with its ask taken off the front
  /// and a trailing "please" off the end. The whole message, if that would leave nothing.
  static func description(in text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var description = trimmed
    var style: String?
    let range = NSRange(trimmed.startIndex..., in: trimmed)
    if let match = ask.firstMatch(in: trimmed, range: range),
      let whole = Range(match.range, in: trimmed)
    {
      description = String(trimmed[whole.upperBound...])
      if let nounRange = Range(match.range(at: 10), in: trimmed) {
        let noun = trimmed[nounRange].lowercased()
        let plain = ["image", "images", "picture", "pictures"]
        if !plain.contains(noun) { style = noun.hasSuffix("s") ? String(noun.dropLast()) : noun }
      }
    } else if let match = imperative.firstMatch(in: trimmed, range: range),
      let whole = Range(match.range, in: trimmed), let verbRange = Range(match.range(at: 5), in: trimmed)
    {
      description = String(trimmed[whole.upperBound...])
      style =
        [
          "draw": "drawing", "paint": "painting", "sketch": "sketch", "illustrate": "illustration",
        ][trimmed[verbRange].lowercased()]
    }
    description = description.replacingOccurrences(
      of: "[,\\s]*\\bplease\\b[.!?\\s]*$", with: "", options: [.regularExpression, .caseInsensitive])
    description = description.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    guard !description.isEmpty else { return trimmed }
    if let style, style != "photo", style != "photograph" { description += ", \(style)" }
    return description
  }

  // MARK: - The two looser readings

  /// Whether a message so much as mentions a picture or the making of one, anywhere in it. Far
  /// too loose to act on alone — "how do I take a better photo" says yes — and used only once
  /// the model has refused: a refusal to a message about pictures is answered with the picture.
  private static let mention = try! NSRegularExpression(
    pattern: "\\b(\(nouns)|draw|paint|sketch|illustrate|render|generate|visuali[sz]e|nude|naked)\\b",
    options: .caseInsensitive)

  static func mightBeAsking(_ text: String) -> Bool {
    mention.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  /// Whether a reply is the model declining rather than answering: the words models are taught
  /// to decline with. Read from the start of the reply, where a refusal is, so a reply that
  /// happens to quote the words further down isn't one.
  private static let refusal = try! NSRegularExpression(
    pattern:
      "^\\W{0,3}(\\w+\\W+){0,12}?(i\\s+(can\\s*not|cannot|can't|won't|will\\s+not|am\\s+unable|'m\\s+unable"
      + "|am\\s+not\\s+able|'m\\s+not\\s+able|do\\s+not|don't)|unable\\s+to|not\\s+able\\s+to"
      + "|safety\\s+guidelines|programmed\\s+to|harmless|against\\s+my|inappropriate"
      + "|as\\s+an\\s+ai|i\\s+apologi[sz]e|sorry,?\\s+but)",
    options: .caseInsensitive)

  static func looksLikeRefusal(_ reply: String) -> Bool {
    // The first sentence only: a refusal opens with itself, and an answer that gets to "I can't
    // stress enough" a sentence in is an answer.
    var head = String(reply.prefix(240))
    if let end = head.range(of: "[.!?](\\s|$)", options: .regularExpression) {
      head = String(head[..<end.lowerBound])
    }
    return refusal.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) != nil
  }

  // MARK: - After a picture

  /// A message that changes the last picture rather than asking for a new one: "make it darker",
  /// "now at night", "another one", "with a hat". Only read when the reply before it was a
  /// picture; on its own any of these could be about anything.
  private static let followUp = try! NSRegularExpression(
    pattern: "^\\s*(make\\s+it|make\\s+them|now|again|another(\\s+one)?|one\\s+more|more|but|with"
      + "|without|same\\s+but|same\\s+thing\\s+but|change|instead|this\\s+time|redo|try\\s+again"
      + "|add|remove|closer|further|darker|lighter|bigger|smaller|as\\s+an?|in\\s+the\\s+style)\\b",
    options: .caseInsensitive)

  static func isFollowUp(_ text: String) -> Bool {
    followUp.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  /// The description a follow-up makes, from the picture before it: the words that carried the
  /// ask taken off, and what is left added to the earlier description. "Again" and "another
  /// one" leave nothing, and the earlier description stands on its own — a new picture of it.
  static func followUpDescription(_ text: String, after previous: String) -> String {
    let stripped = text.replacingOccurrences(
      of: "^\\s*(make\\s+it|make\\s+them|now|again|another(\\s+one)?|one\\s+more|same\\s+but"
        + "|same\\s+thing\\s+but|this\\s+time|redo|try\\s+again|but|instead)\\b[,:\\s]*",
      with: "", options: [.regularExpression, .caseInsensitive]
    )
    .replacingOccurrences(
      of: "[,\\s]*\\bplease\\b[.!?\\s]*$", with: "", options: [.regularExpression, .caseInsensitive]
    )
    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    return stripped.isEmpty ? previous : "\(previous), \(stripped)"
  }
}
