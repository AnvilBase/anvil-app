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
    guard let generate = ToolSession.shared.imageGenerator else {
      // Asked for a picture that can't be made: the chat is told why, so it can open the Pro page
      // or point at the download, and the model is told what to say.
      if let why = ToolSession.shared.imageUnavailability {
        ToolSession.shared.send(.imageUnavailable(why))
        return ["error": why.modelNote]
      }
      return ["error": "Image generation isn't available right now."]
    }
    ToolSession.shared.send(.generatingImage(trimmed))
    do {
      let data = try await generate(trimmed)
      ToolSession.shared.send(.imageGenerated(data, prompt: trimmed))
      return [
        "generated": true,
        "prompt": trimmed,
        "note": "The picture is already on screen above your reply. Add one short sentence about "
          + "it. Don't describe it in detail and don't say you can't show images.",
      ]
    } catch {
      ToolSession.shared.send(.imageGenerationFailed(error.localizedDescription))
      return ["error": "The picture couldn't be made: \(error.localizedDescription)"]
    }
  }
}
