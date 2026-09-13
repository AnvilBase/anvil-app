import Foundation
import LiteRTLM

/// Runs the model on this iPhone with LiteRT-LM.
///
/// An actor owning the one engine and the one active conversation, so loading a multi-gigabyte model
/// and generating from it never block the main thread. Nothing here touches the network.
actor OnDeviceEngine {
  struct LoadResult: Sendable {
    let details: ModelDetails
    /// Shown to the user when the preferred configuration couldn't be used.
    let notice: String?
  }

  enum EngineError: LocalizedError {
    case notLoaded
    /// Every configuration was tried and none took. Each is named with what it said, because the
    /// first one to fail — the GPU — is rarely the one that explains why; the CPU's reason usually
    /// is, and a screen that shows only the first leaves someone re-downloading a good file.
    case allAttemptsFailed([(configuration: String, reason: String)])

    var errorDescription: String? {
      switch self {
      case .notLoaded:
        return "The model is not loaded."
      case .allAttemptsFailed(let attempts):
        return attempts.map { "\($0.configuration): \($0.reason)" }.joined(separator: "\n")
      }
    }
  }

  /// One configuration to try while loading, in order of preference.
  private struct Attempt {
    let backend: Backend
    let vision: Backend?
    let notice: String?
  }

  /// What the model file itself says it can do.
  private struct FileCapabilities {
    let supportsThinking: Bool
    let supportsImages: Bool
    let supportsAudio: Bool
    let supportsToolCalling: Bool
    let defaultSampler: SamplerValues?
  }

  private var engine: Engine?
  private var conversation: Conversation?

  /// Loads the model, trying the preferred configuration first and falling back when it fails.
  /// Vision runs on the CPU, matching LiteRT-LM's multimodal configuration guidance.
  func load(model: ModelFile, options: EngineOptions) async throws -> LoadResult {
    unload()
    let cacheDirectory = try ModelFiles.cacheDirectory().path
    enableBenchmarkCounters()
    let capabilities = Self.readCapabilities(modelPath: model.url.path)
    let wantImages = options.imageInput && (capabilities?.supportsImages ?? true)

    var failures: [(configuration: String, reason: String)] = []
    for attempt in Self.attempts(for: options.backend, images: wantImages) {
      let started = ContinuousClock.now
      do {
        let config = try EngineConfig(
          modelPath: model.url.path,
          backend: attempt.backend,
          visionBackend: attempt.vision,
          maxNumTokens: options.contextSize,
          cacheDir: cacheDirectory)
        let candidate = Engine(engineConfig: config)
        try await candidate.initialize()
        // Creating a conversation proves the configuration works; chats replace it on first send.
        conversation = try await candidate.createConversation()
        engine = candidate

        let details = ModelDetails(
          fileName: model.url.lastPathComponent,
          fileSize: model.fileSize,
          backend: Self.name(of: attempt.backend),
          imageBackend: attempt.vision.map { Self.name(of: $0) },
          contextSize: options.contextSize,
          loadSeconds: started.duration(to: .now).inSeconds,
          supportsThinking: capabilities?.supportsThinking ?? false,
          supportsImages: attempt.vision != nil,
          supportsAudio: capabilities?.supportsAudio ?? false,
          supportsToolCalling: capabilities?.supportsToolCalling ?? false,
          defaultSampler: capabilities?.defaultSampler)
        return LoadResult(details: details, notice: attempt.notice)
      } catch {
        let images = attempt.vision == nil ? "" : " with images"
        let configuration = Self.name(of: attempt.backend) + images
        failures.append((configuration, error.localizedDescription))
        conversation = nil
      }
    }
    throw EngineError.allAttemptsFailed(failures)
  }

  func unload() {
    conversation = nil
    engine = nil
  }

  /// Starts a conversation that continues `history`. Returns false when the history couldn't be
  /// restored (most often because it no longer fits the context) and the conversation starts empty.
  func startConversation(_ options: ConversationOptions, history: [HistoryTurn]) async throws -> Bool {
    guard let engine else { throw EngineError.notLoaded }
    // Release the old session first: the engine supports one active session at a time.
    conversation = nil

    let systemMessage = Message(PromptBuilder.systemPrompt(for: options), role: .system)
    let sampler = try options.sampler.map {
      try SamplerConfig(topK: $0.topK, topP: Float($0.topP), temperature: Float($0.temperature))
    }
    let thinking = options.thinking ? ThinkingConfig(enableThinking: true) : nil
    let tools = ToolRegistry.tools(for: options)
    let initialMessages = history
      .filter { !$0.text.isEmpty }
      .map { Message($0.text, role: $0.isUser ? .user : .model) }

    do {
      conversation = try await engine.createConversation(
        with: ConversationConfig(
          systemMessage: systemMessage, initialMessages: initialMessages, tools: tools,
          samplerConfig: sampler, thinkingConfig: thinking))
      return true
    } catch {
      guard !initialMessages.isEmpty else { throw error }
      conversation = try await engine.createConversation(
        with: ConversationConfig(
          systemMessage: systemMessage, tools: tools, samplerConfig: sampler,
          thinkingConfig: thinking))
      return false
    }
  }

  /// Streams one reply. `imageData` goes ahead of the text when there's a photo, and `webSearch`
  /// supplies the key for any searches the model makes while it writes.
  func stream(
    _ text: String, imageData: Data?, maxReplyTokens: Int?, webSearch: WebSearchConfig?
  ) throws -> AsyncThrowingStream<ReplyEvent, Error> {
    guard let conversation else { throw EngineError.notLoaded }
    return AsyncThrowingStream { continuation in
      ToolSession.shared.begin(webSearch: webSearch) { event in continuation.yield(event) }
      let task = Task {
        defer { ToolSession.shared.end() }
        do {
          var contents: [Content] = []
          if let imageData { contents.append(.imageData(imageData)) }
          contents.append(.text(text))
          let message = Message(contents: contents)
          for try await chunk in conversation.sendMessageStream(message, maxOutputTokens: maxReplyTokens) {
            // Reasoning arrives on a named channel ("thought" for Gemma); tool-call channels are skipped.
            let thought = chunk.channels.filter { !$0.key.contains("tool") }.map(\.value).joined()
            if !thought.isEmpty { continuation.yield(.thinking(thought)) }
            let piece = chunk.toString
            if !piece.isEmpty { continuation.yield(.text(piece)) }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { termination in
        if case .cancelled = termination {
          task.cancel()
          try? conversation.cancel()
        }
      }
    }
  }

  /// Asks the engine to stop generating. The active stream then finishes on its own.
  func cancel() {
    try? conversation?.cancel()
  }

  /// Counters for the most recent reply. Call it once that reply's stream has finished.
  func replyCounters() -> ReplyCounters {
    guard let conversation else { return ReplyCounters() }
    var counters = ReplyCounters(contextTokens: try? conversation.getTokenCount())
    if ExperimentalFlags.enableBenchmark, let info = try? conversation.getBenchmarkInfo() {
      counters.promptTokens = info.lastPrefillTokenCount
      counters.replyTokens = info.lastDecodeTokenCount
      counters.prefillTokensPerSecond =
        info.lastPrefillTokensPerSecond > 0 ? info.lastPrefillTokensPerSecond : nil
      counters.decodeTokensPerSecond =
        info.lastDecodeTokensPerSecond > 0 ? info.lastDecodeTokensPerSecond : nil
    }
    return counters
  }

  /// Token counts and speeds come from LiteRT-LM's experimental benchmark counters, read when the
  /// engine is created. No fixed benchmark token counts are set, so replies are unaffected: the
  /// engine still tokenizes the real prompt and stops at the model's own stop tokens.
  private func enableBenchmarkCounters() {
    ExperimentalFlags.optIntoExperimentalAPIs()
    ExperimentalFlags.enableBenchmark = true
  }

  private static func readCapabilities(modelPath: String) -> FileCapabilities? {
    guard let capabilities = Capabilities(modelPath: modelPath) else { return nil }
    let modalities = capabilities.inputModalities
    let params = capabilities.defaultSamplerParams
    // Files without sampling defaults report zeros.
    let sampler =
      params.topK > 0
      ? SamplerValues(
        temperature: Double(params.temperature), topK: params.topK, topP: Double(params.topP))
      : nil
    return FileCapabilities(
      supportsThinking: capabilities.supportsThinking(),
      supportsImages: modalities.vision,
      supportsAudio: modalities.audio,
      supportsToolCalling: capabilities.supportsFunctionCalling(),
      defaultSampler: sampler)
  }

  /// GPU first, then CPU; with images, the same again without the vision encoder. Each fallback
  /// carries the sentence shown to the user if it's the one that works.
  private static func attempts(for preference: EngineBackendPreference, images: Bool) -> [Attempt] {
    let noImages =
      images ? "Image input is unavailable because the vision encoder failed to load." : nil
    var attempts: [Attempt] = []
    if preference != .cpu {
      if images { attempts.append(Attempt(backend: .gpu, vision: .cpu(), notice: nil)) }
      attempts.append(Attempt(backend: .gpu, vision: nil, notice: noImages))
    }
    if preference != .gpu {
      let fellBack =
        preference == .automatic
        ? "GPU initialization failed, so the model is running on the CPU (slower)." : nil
      if images { attempts.append(Attempt(backend: .cpu(), vision: .cpu(), notice: fellBack)) }
      let notices = [fellBack, noImages].compactMap { $0 }
      attempts.append(
        Attempt(
          backend: .cpu(), vision: nil,
          notice: notices.isEmpty ? nil : notices.joined(separator: " ")))
    }
    return attempts
  }

  private static func name(of backend: Backend) -> String {
    backend.rawValue.uppercased()
  }
}
