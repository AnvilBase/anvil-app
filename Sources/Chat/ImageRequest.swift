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
  ]

  static func isAsking(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
  }
}
