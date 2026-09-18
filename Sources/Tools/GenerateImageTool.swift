import Foundation
import LiteRTLM

/// Lets the model make a picture with Anvil Dream.
///
/// The picture is generated on this iPhone through the tool session and goes straight into the
/// reply as it finishes; what the model gets back is a note that it is there, so it can say a word
/// about it rather than describe a picture it can't see.
struct GenerateImageTool: Tool {
  static let name = "generate_image"
  static let description =
    "Make a picture from a description, on the user's phone. Use it whenever the user asks for an "
    + "image, picture, drawing, painting, illustration, or photo of something. Write the prompt as "
    + "one detailed visual description in English: the subject, the setting, the style, the light."

  @ToolParam(
    description:
      "What the picture should show, as one detailed sentence, such as \"A red fox in tall grass "
      + "at dawn, soft light, watercolor\".")
  var prompt: String

  func run() async throws -> Any {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ["error": "The prompt is empty."] }
    guard ToolSession.shared.imageGenerator != nil else {
      return ["error": "Image generation isn't available right now."]
    }
    // Asked for here, made after the reply. Making it now, in the middle of the model's turn,
    // meant the chat model and the picture model in memory at once — which on an 8 GB phone
    // is minutes of thrashing or the app killed. The chat finishes its sentence, sets its
    // model down, paints, and picks the model up again.
    ToolSession.shared.send(.imageDeferred(trimmed))
    return [
      "generated": true,
      "prompt": trimmed,
      "note": "The picture will appear under your reply in a moment. Add one short sentence "
        + "saying it's on its way. Don't describe it in detail and don't say you can't show "
        + "images.",
    ]
  }
}
