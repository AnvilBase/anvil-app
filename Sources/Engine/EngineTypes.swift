import Foundation

/// What the app knows about the loaded model and how it was loaded.
struct ModelDetails: Equatable, Sendable {
  var fileName: String
  var fileSize: Int64
  var backend: String
  var imageBackend: String?
  var contextSize: Int
  var loadSeconds: Double
  var supportsThinking: Bool
  var supportsImages: Bool
  var supportsAudio: Bool
  var supportsToolCalling: Bool
  /// Sampling defaults stored in the model file, if it has any.
  var defaultSampler: SamplerValues?
}

/// Everything baked into a conversation when it is created: the instructions the model follows and
/// the tools it can call. A change to any of it means starting a new conversation.
///
/// Configures the model on this iPhone: every conversation is built from the same guidance and the
/// same tools.
struct ConversationOptions: Equatable, Sendable {
  var systemPrompt: String
  var sampler: SamplerValues?
  var thinking: Bool
  /// Gives the model the web_search tool.
  var webSearch: Bool
  /// Gives the model the save_memory tool, and the facts it has already saved.
  var memoryEnabled: Bool
  var memories: [String]
  /// Whether a picture can actually be made: Anvil Dream is installed and Pro is active. The
  /// generate_image tool is offered either way, so that asking for a picture without Pro leads to
  /// the Pro page rather than nowhere; this decides what the tool does when called.
  var imageGeneration = false
  /// Talk mode: the reply is going to be spoken, so it should be written to be heard.
  var spokenReplies = false
}

/// One past message, trimmed to text, as it is given back to a model.
struct HistoryTurn: Sendable {
  let isUser: Bool
  let text: String
}

/// Everything that can happen while a reply is being written. Both engines emit these, and the chat
/// applies them to the message on screen.
enum ReplyEvent: Sendable {
  case text(String)
  case thinking(String)
  case searching(String)
  case sources([WebSource])
  case searchError(String)
  case memorySaved(String)
  /// Anvil Dream has started on a picture with this prompt.
  case generatingImage(String)
  /// The picture, as JPEG data, and what it was made from.
  case imageGenerated(Data, prompt: String)
  case imageGenerationFailed(String)
  /// The model asked for a picture and none can be made: the chat shows what is needed.
  case imageUnavailable(ImageUnavailability)
}

/// Why a picture can't be made right now, in the order they are fixed: Pro first, then the model.
enum ImageUnavailability: Sendable {
  case needsPro
  case needsDream

  /// What the tool tells the model, so the reply says the right thing in a sentence.
  var modelNote: String {
    switch self {
    case .needsPro:
      "Making pictures is part of Anvil Pro, which the user doesn't have. The Anvil Pro page has "
        + "been opened for them. Tell them, in one short sentence, that pictures come with Anvil Pro."
    case .needsDream:
      "Anvil Dream, the picture model, isn't installed. Tell the user, in one short sentence, to "
        + "download Anvil Dream under Models in Settings."
    }
  }
}

/// Token counts and speeds for the reply that just finished.
struct ReplyCounters: Sendable {
  var contextTokens: Int?
  var promptTokens: Int?
  var replyTokens: Int?
  var prefillTokensPerSecond: Double?
  var decodeTokensPerSecond: Double?
}
