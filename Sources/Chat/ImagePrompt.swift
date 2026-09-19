import Foundation

/// Fills out a description before it is painted, so the model has something to follow.
///
/// A diffusion model steers by the difference between what the prompt asks for and what it would
/// have drawn unasked. Say a lot and that difference is large and the picture is yours. Say almost
/// nothing — "banana", "the sea" — and the two are nearly the same thing, the difference is nearly
/// nothing, and no amount of guidance can amplify nothing: what comes back is whatever the weights
/// hold by default. Anvil Dream's default, like most photoreal models trained off the open web,
/// is a woman with no clothes on. "Generate a banana" returned exactly that.
///
/// So the short description is not sent short. What the message named stays first and unaltered —
/// this adds, never replaces — and behind it goes the frame a photographer would have set anyway:
/// the whole subject in shot, lit plainly, against nothing in particular. Those words are not
/// decoration. "The whole subject in frame" and "plain uncluttered background" are the two that
/// argue hardest against a cropped body, which is the shape the default wants to take.
///
/// How much is added depends on how little was said. A description that already runs to a
/// sentence is given a touch; one word is given the lot. A picture asked for in detail is already
/// steering itself and does not need help.
enum ImagePrompt {
  /// Words that carry no picture in them, and so do not count towards how much was said.
  private static let empty: Set<String> = [
    "a", "an", "the", "of", "in", "on", "at", "with", "and", "or", "to", "for", "my", "me",
    "some", "this", "that", "it", "is", "are", "by", "from", "as", "into", "over", "under",
  ]

  /// Mediums that are drawn rather than photographed. Named in the description, they decide which
  /// frame is put behind it: a pencil drawing wants clean line work, not a 50mm lens.
  private static let drawnMediums: Set<String> = [
    "drawing", "drawn", "sketch", "sketched", "painting", "painted", "illustration", "illustrated",
    "artwork", "watercolour", "watercolor", "oil", "pencil", "ink", "charcoal", "pastel", "comic",
    "cartoon", "anime", "manga", "pixel", "vector", "logo", "icon", "poster", "blueprint",
    "engraving", "woodcut", "collage", "mural", "graffiti", "tattoo",
  ]

  /// Mediums that are already photographs, so the frame does not have to say so again.
  private static let photographicMediums: Set<String> = [
    "photo", "photograph", "photography", "photographic", "snapshot", "polaroid", "portrait",
  ]

  /// How much was actually said, which decides how much is put behind it.
  private enum Told {
    /// A word or two. "Banana." Everything the picture is beyond that noun is the model's guess.
    case barely
    /// A short phrase — a subject and a little around it.
    case thinly
    /// A sentence. It is steering itself; leave it be but for the sharpness.
    case fully
  }

  /// The words a description actually spends on the picture.
  private static func told(in description: String) -> Told {
    let words = description
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { !empty.contains($0) }
    switch words.count {
    case ...2: return .barely
    case 3...5: return .thinly
    default: return .fully
    }
  }

  private static func names(_ mediums: Set<String>, in description: String) -> Bool {
    description
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .contains { mediums.contains(String($0)) }
  }

  /// The description as it should be painted: what was asked for, then the frame behind it.
  static func expanded(_ description: String) -> String {
    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    let drawn = names(drawnMediums, in: trimmed)
    let photographic = names(photographicMediums, in: trimmed)

    var frame: [String]
    switch (told(in: trimmed), drawn) {
    case (.barely, true):
      frame = [
        "the whole subject in frame", "centred composition", "clean line work",
        "even lighting", "plain background", "fine detail",
      ]
    case (.barely, false):
      // The one that had nothing to go on. It gets the most, and it gets told it is a photograph,
      // since a model asked for "banana" and nothing else has to decide even that for itself.
      frame = [
        "the whole subject in frame", "centred composition", "natural daylight",
        "plain uncluttered background", "sharp focus", "fine detail",
      ]
      if !photographic { frame.insert("a clear photograph", at: 0) }
    case (.thinly, true):
      frame = ["clean line work", "even lighting", "fine detail"]
    case (.thinly, false):
      frame = ["natural daylight", "sharp focus", "fine detail"]
    case (.fully, _):
      frame = ["sharp focus", "fine detail"]
    }
    return ([trimmed] + frame).joined(separator: ", ")
  }
}
