import CoreGraphics
import Foundation
import Observation

/// Everything the chat screens read and act on: the open chat, saved history, where replies run,
/// dictation, and per-reply measurements.
///
/// It owns both engines — the model on this iPhone (`OnDeviceEngine`) and the one on your computer
/// (`ComputerEngine`) — and decides which of them writes each reply.
@MainActor
@Observable
final class ChatModel {
  enum LoadState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
  }

  private(set) var openChat: Chat
  private(set) var savedChats: [Chat] = []
  private(set) var loadState: LoadState = .idle
  private(set) var isGenerating = false
  private(set) var isStopping = false
  /// Shown when the model loaded with a fallback configuration.
  private(set) var notice: String?
  /// Shown for problems with this chat, such as history that didn't fit or a search that failed.
  private(set) var chatNotice: String?
  private(set) var pendingImage: PreparedImage?
  private(set) var isPreparingImage = false
  /// Decoded photos for the open chat, keyed by message ID.
  private(set) var images: [ChatMessage.ID: CGImage] = [:]
  private(set) var modelDetails: ModelDetails?
  /// The engine options the model on this iPhone is currently loaded with.
  private(set) var loadedEngineOptions: EngineOptions?
  /// Tokens held by the engine's conversation after the latest reply.
  private(set) var contextTokens: Int?
  private(set) var totals = UsageTotals()
  /// The past message being edited. Sending replaces it and everything after it.
  private(set) var editingMessageID: ChatMessage.ID?
  private(set) var hasComputerToken = ComputerTokenStore.read() != nil
  private(set) var isTestingComputer = false
  private(set) var computerTestResult: String?
  private(set) var computerState: ComputerState = .notUsed
  /// A pairing link waiting for you to confirm it.
  private(set) var pendingPairing: PairingLink?
  var draft = ""
  var alertMessage: String?

  let settings: SettingsStore
  let network = NetworkStatus()
  let memory = MemoryStore()
  let speechInput = SpeechInput()
  private let device = OnDeviceEngine()
  private let archive = ChatArchive()
  private var loadedModel: ModelFile?
  private var generationTask: Task<Void, Never>?
  /// True while the current reply is coming from your computer, so Stop cancels the request at once.
  private var generatingOnComputer = false
  /// When `computerState` was last checked.
  private var computerCheckedAt: ContinuousClock.Instant?
  /// How the engine's current conversation was created. nil means it no longer matches the open
  /// chat, so the next send rebuilds one from history.
  private var activeConversation: ConversationOptions?

  /// Automatic won't wait on a computer that was unreachable more recently than this.
  private static let unreachableRetryDelay: Duration = .seconds(30)

  private struct ComputerConnection {
    let url: URL
    let token: String?
    let status: ComputerStatus
  }

  init(settings: SettingsStore) {
    self.settings = settings
    openChat = Chat(systemPrompt: settings.values.systemPrompt)
  }

  // MARK: - What the screens ask

  var messages: [ChatMessage] { openChat.messages }

  var supportsImages: Bool { modelDetails?.supportsImages ?? false }

  /// Whether this build carries a Brave Search key (Config/Local.xcconfig).
  var hasSearchKey: Bool { AppSecrets.hasBraveSearchKey }

  var isOffline: Bool { !network.isOnline }

  /// Whether replies can search right now. Your preference is kept while offline, and search comes
  /// back on by itself when the connection returns.
  var webSearchOn: Bool { settings.values.webSearchEnabled && hasSearchKey && network.isOnline }

  var canSend: Bool {
    loadState == .ready && !isGenerating && !isPreparingImage
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil)
  }

  /// True when engine settings have changed since the model was loaded.
  var needsReload: Bool {
    loadedEngineOptions.map { $0 != settings.values.engine } ?? false
  }

  /// Where replies run, for the status line. nil when they run on this iPhone.
  var replyLocationLabel: String? {
    switch settings.values.replyLocation {
    case .iPhone: nil
    case .computer: "Replies on your computer"
    case .automatic: "Replies on your computer when it's reachable"
    }
  }

  // MARK: - The model on this iPhone

  func load(_ model: ModelFile, force: Bool = false) async {
    guard force || model != loadedModel else { return }
    await stopGeneration()
    loadedModel = model
    loadState = .loading
    notice = nil
    activeConversation = nil

    // If the last load never finished, it took the whole process with it — almost always by running
    // out of memory. Trying the same thing again would do the same thing again, and the app would
    // never stay up long enough to change a setting, so back something off first.
    var options = settings.values.engine
    var memoryNotice: String?
    if let abandoned = LoadAttempt.abandoned(), abandoned == options {
      if let reduced = options.afterRunningOutOfMemory() {
        let changes = reduced.differences(from: options)
        options = reduced
        settings.values.engine = reduced
        settings.save()
        memoryNotice =
          "The model ran this iPhone out of memory, so "
          + changes.formatted(.list(type: .and)) + ". Change it back in Settings › Model."
      } else {
        LoadAttempt.succeeded()
        modelDetails = nil
        loadedEngineOptions = nil
        loadState = .failed(
          "This model needs more memory than iOS will give the app, even with image input off and "
            + "the smallest context. A smaller model is the way forward.")
        return
      }
    }
    LoadAttempt.begin(options)

    do {
      let result = try await device.load(model: model, options: options)
      LoadAttempt.succeeded()
      guard loadedModel == model else { return }  // A newer import superseded this load.
      modelDetails = result.details
      loadedEngineOptions = options
      notice = memoryNotice ?? result.notice
      if !result.details.supportsImages { pendingImage = nil }
      loadState = .ready
    } catch {
      LoadAttempt.succeeded()
      guard loadedModel == model else { return }
      modelDetails = nil
      loadedEngineOptions = nil
      loadState = .failed(
        "\(error.localizedDescription)\n\nThe file may be incomplete or not a LiteRT-LM model, "
          + "or the phone may not have enough free memory.")
    }
  }

  func reloadModel() async {
    guard let loadedModel else { return }
    await load(loadedModel, force: true)
  }

  func unload() async {
    await stopGeneration()
    loadedModel = nil
    loadState = .idle
    pendingImage = nil
    modelDetails = nil
    loadedEngineOptions = nil
    activeConversation = nil
    await device.unload()
  }

  func setWebSearch(_ enabled: Bool) {
    settings.values.webSearchEnabled = enabled
    settings.save()
  }

  // MARK: - Your computer

  /// Saves the access token to the Keychain, or removes it when empty.
  func saveComputerToken(_ token: String) {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      ComputerTokenStore.delete()
    } else if !ComputerTokenStore.save(trimmed) {
      alertMessage = "Couldn't save the token to the Keychain."
    }
    hasComputerToken = ComputerTokenStore.read() != nil
    computerTestResult = nil
  }

  func testComputerConnection() async {
    settings.save()
    guard let url = ComputerAddress.url(from: settings.values.computerAddress) else {
      computerTestResult = "Enter your computer's HTTPS address, like https://your-pc.tailnet.ts.net."
      return
    }
    isTestingComputer = true
    defer { isTestingComputer = false }
    do {
      let status = try await ComputerEngine.status(
        baseURL: url, token: ComputerTokenStore.read(), timeout: 5)
      computerTestResult = "Connected: \(status.summary)"
      if settings.values.replyLocation != .iPhone { computerState = .online(status) }
    } catch {
      computerTestResult = "Couldn't connect. \(error.localizedDescription)"
      if settings.values.replyLocation != .iPhone {
        computerState = .unreachable(error.localizedDescription)
      }
    }
    computerCheckedAt = .now
  }

  /// Checks whether your computer is reachable, for the toolbar dot and Automatic routing.
  func refreshComputerStatus() async {
    guard settings.values.replyLocation != .iPhone else {
      computerState = .notUsed
      return
    }
    guard let url = ComputerAddress.url(from: settings.values.computerAddress) else {
      computerState = .notConfigured
      return
    }
    guard network.isOnline else {
      computerState = .unreachable(ComputerError.offline.localizedDescription)
      computerCheckedAt = .now
      return
    }
    if case .online = computerState {} else { computerState = .checking }
    do {
      let status = try await ComputerEngine.status(
        baseURL: url, token: ComputerTokenStore.read(), timeout: 3)
      computerState =
        status.isReady
        ? .online(status)
        : .unreachable(ComputerError.notReady(status.modelServer ?? "starting").localizedDescription)
    } catch {
      computerState = .unreachable(error.localizedDescription)
    }
    computerCheckedAt = .now
  }

  /// Handles a pairing link. Nothing is saved until you confirm it.
  func handleOpenURL(_ url: URL) {
    guard let pairing = PairingLink(url: url) else {
      alertMessage = "That link isn't a valid \(AppFlavor.appName) pairing code."
      return
    }
    pendingPairing = pairing
  }

  /// Saves the address and token from a confirmed pairing link, then checks the connection.
  func acceptPairing(_ pairing: PairingLink) {
    pendingPairing = nil
    settings.values.computerAddress = pairing.url.absoluteString
    if settings.values.replyLocation == .iPhone { settings.values.replyLocation = .computer }
    settings.save()
    saveComputerToken(pairing.token)
    computerCheckedAt = nil
    Task { await refreshComputerStatus() }
  }

  func cancelPairing() {
    pendingPairing = nil
  }

  // MARK: - Sending

  func send() {
    guard canSend else { return }
    let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let image = pendingImage
    draft = ""
    pendingImage = nil

    var removedImageIDs: [ChatMessage.ID] = []
    if let editingMessageID {
      removedImageIDs = truncate(from: editingMessageID)
      self.editingMessageID = nil
    }
    submit(typed, image: image, removedImageIDs: removedImageIDs)
  }

  /// Starts or stops dictation. Speech is recognized on this iPhone and typed into the message
  /// field; with "send when you stop talking" on, the message goes as soon as you pause.
  func toggleDictation() {
    if speechInput.isActive {
      speechInput.stop()
      return
    }
    guard loadState == .ready, !isGenerating else { return }
    let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let autoSend = settings.values.autoSendVoice
    Task {
      do {
        try await speechInput.start(
          stopAfterSilence: autoSend,
          onUpdate: { [weak self] transcript in
            self?.draft = existing.isEmpty ? transcript : "\(existing) \(transcript)"
          },
          onFinish: { [weak self] transcript in
            guard let self, autoSend, !transcript.isEmpty else { return }
            send()
          })
      } catch {
        alertMessage = error.localizedDescription
      }
    }
  }

  /// True for the last reply, when it answers one of your messages and nothing else is in progress.
  func canRegenerate(_ id: ChatMessage.ID) -> Bool {
    let messages = openChat.messages
    guard loadState == .ready, !isGenerating, !isPreparingImage, editingMessageID == nil,
      let last = messages.last, last.id == id, last.role == .assistant,
      let prompt = messages.dropLast().last, prompt.role == .user
    else { return false }
    return !prompt.text.isEmpty || prompt.hasImage
  }

  /// Replaces the last reply with a new one for the same message and photo.
  func regenerate(_ id: ChatMessage.ID) {
    guard canRegenerate(id), let prompt = openChat.messages.dropLast().last else { return }
    let chatID = openChat.id
    isPreparingImage = prompt.hasImage
    Task {
      var image: PreparedImage?
      if prompt.hasImage, let preview = images[prompt.id],
        let data = await archive.loadImage(chatID: chatID, messageID: prompt.id)
      {
        image = PreparedImage(jpegData: data, preview: preview)
      }
      isPreparingImage = false
      guard openChat.id == chatID, canRegenerate(id), !prompt.text.isEmpty || image != nil else {
        return
      }
      let removedImageIDs = truncate(from: prompt.id)
      submit(prompt.text, image: image, removedImageIDs: removedImageIDs)
    }
  }

  func stop() {
    guard let task = generationTask, !isStopping else { return }
    isStopping = true
    if generatingOnComputer {
      // Cancelling the request closes the connection, which stops generation on the computer.
      task.cancel()
      return
    }
    Task {
      await device.cancel()
      // If the engine doesn't close the stream promptly, stop listening to it.
      try? await Task.sleep(for: .seconds(3))
      task.cancel()
    }
  }

  // MARK: - Editing

  /// Puts a past message of yours back in the input field.
  func beginEditing(_ id: ChatMessage.ID) {
    guard !isGenerating,
      let message = openChat.messages.first(where: { $0.id == id }), message.role == .user
    else { return }
    editingMessageID = id
    draft = message.text
    pendingImage = nil

    guard message.hasImage, let preview = images[id] else { return }
    isPreparingImage = true
    let chatID = openChat.id
    Task {
      let data = await archive.loadImage(chatID: chatID, messageID: id)
      if editingMessageID == id, let data {
        pendingImage = PreparedImage(jpegData: data, preview: preview)
      }
      isPreparingImage = false
    }
  }

  func cancelEditing() {
    editingMessageID = nil
    draft = ""
    pendingImage = nil
  }

  /// True for the message being edited and every message after it, which sending will replace.
  func isReplacedByEdit(_ id: ChatMessage.ID) -> Bool {
    guard let editingMessageID,
      let start = openChat.messages.firstIndex(where: { $0.id == editingMessageID }),
      let index = openChat.messages.firstIndex(where: { $0.id == id })
    else { return false }
    return index >= start
  }

  // MARK: - History

  /// Loads usage totals and saved chats, deleting any past the retention period.
  func restoreHistory() async {
    totals = await archive.loadTotals()
    await purgeExpiredChats()
  }

  func purgeExpiredChats() async {
    let deleted = await archive.purge(olderThanDays: settings.values.historyRetentionDays)
    if deleted.contains(openChat.id), !isGenerating { startNewChat() }
    savedChats = await archive.loadAll()
  }

  func newChat() {
    Task {
      await stopGeneration()
      startNewChat()
    }
  }

  func open(_ id: Chat.ID) {
    Task {
      await stopGeneration()
      guard id != openChat.id, let saved = savedChats.first(where: { $0.id == id }) else { return }
      startNewChat()
      openChat = saved

      var loaded: [ChatMessage.ID: CGImage] = [:]
      for message in saved.messages where message.hasImage {
        if let data = await archive.loadImage(chatID: saved.id, messageID: message.id),
          let image = ImageProcessing.decode(data)
        {
          loaded[message.id] = image
        }
      }
      if openChat.id == saved.id { images = loaded }
    }
  }

  func deleteChat(_ id: Chat.ID) {
    Task {
      if id == openChat.id {
        await stopGeneration()
        startNewChat()
      }
      do {
        try await archive.delete(id)
        savedChats.removeAll { $0.id == id }
      } catch {
        alertMessage = "Couldn't delete the chat: \(error.localizedDescription)"
      }
    }
  }

  func deleteAllChats() {
    Task {
      await stopGeneration()
      startNewChat()
      do {
        try await archive.deleteAll()
        savedChats = []
      } catch {
        alertMessage = "Couldn't delete chats: \(error.localizedDescription)"
      }
    }
  }

  /// Saves settings and applies the parts that don't need the model reloaded.
  func settingsDidClose() async {
    settings.save()
    if openChat.messages.isEmpty { openChat.systemPrompt = settings.values.systemPrompt }
    await purgeExpiredChats()
    await refreshComputerStatus()
  }

  func resetTotals() {
    totals = UsageTotals()
    let cleared = totals
    Task { try? await archive.saveTotals(cleared) }
  }

  // MARK: - Photos

  func attachImage(_ data: Data) async {
    isPreparingImage = true
    defer { isPreparingImage = false }
    let prepared = await Task.detached(priority: .userInitiated) {
      ImageProcessing.prepare(data)
    }.value
    if let prepared {
      pendingImage = prepared
    } else {
      alertMessage = "That image couldn't be read."
    }
  }

  func removePendingImage() {
    pendingImage = nil
  }

  // MARK: - Writing a reply

  /// Adds your message and streams the reply to it, from your computer or from this iPhone.
  private func submit(_ typed: String, image: PreparedImage?, removedImageIDs: [ChatMessage.ID]) {
    if openChat.messages.isEmpty {
      // An empty chat picks up the latest system prompt from Settings.
      openChat.systemPrompt = settings.values.systemPrompt
      openChat.title = Self.title(for: typed)
    }

    let history = openChat.messages
    let user = ChatMessage(role: .user, text: typed, hasImage: image != nil)
    let reply = ChatMessage(role: .assistant, text: "")
    if let image { images[user.id] = image.preview }
    openChat.messages.append(contentsOf: [user, reply])
    openChat.updatedAt = Date()
    isGenerating = true
    chatNotice = nil

    let webSearch =
      webSearchOn
      ? WebSearchConfig(
        apiKey: AppSecrets.braveSearchAPIKey, resultCount: settings.values.webSearchResultCount)
      : nil
    let options = conversationOptions()
    // With only a photo attached, give the model something to do with it.
    let basePrompt = typed.isEmpty ? "Describe this image." : typed
    // Models keep answering the way they already have in a chat, so say when search was switched on
    // or off since the last reply (or is on in a chat being reopened). Only the model sees this.
    let searchChanged = activeConversation.map { $0.webSearch != options.webSearch } ?? options.webSearch
    let searchNote =
      history.isEmpty || !searchChanged
      ? nil : PromptBuilder.searchChangeNote(webSearchOn: options.webSearch)
    let prompt = searchNote.map { "\($0)\n\n\(basePrompt)" } ?? basePrompt
    let contextLimit = modelDetails?.contextSize ?? settings.values.engine.contextSize
    let maxReplyTokens = settings.values.maxReplyTokens
    let sampler = settings.values.useModelSamplerDefaults ? nil : settings.values.sampler
    let thinkingRequested = settings.values.thinkingEnabled
    let deviceBackend = modelDetails?.backend ?? "Unknown"
    let chatID = openChat.id

    generationTask = Task {
      for id in removedImageIDs {
        await archive.deleteImage(chatID: chatID, messageID: id)
      }
      if let image {
        try? await archive.saveImage(image.jpegData, chatID: chatID, messageID: user.id)
      }
      await save()

      let monitor = DeviceMetrics.monitorPeaks()
      let started = ContinuousClock.now
      var firstPiece: Duration?
      var computer: ComputerConnection?
      var computerTimings: ReplyTimings?

      do {
        computer = try await computerRoute()
        if let connection = computer {
          generatingOnComputer = true
          // This turn isn't in the iPhone engine's conversation, so rebuild it if that engine is
          // used next.
          activeConversation = nil
          let sendPhoto = connection.status.vision != false
          if image != nil, !sendPhoto {
            chatNotice = "The model on your computer can't read photos, so only your text was sent."
          }
          let request = ComputerRequest(
            options: options,
            history: Self.historyTurns(history, contextSize: connection.status.context ?? 8192),
            prompt: prompt,
            imageJPEG: sendPhoto ? image?.jpegData : nil,
            sampler: sampler,
            maxTokens: maxReplyTokens > 0 ? maxReplyTokens : nil,
            thinking: thinkingRequested,
            webSearch: webSearch)
          do {
            for try await event in ComputerEngine.stream(
              request, baseURL: connection.url, token: connection.token)
            {
              switch event {
              case .reply(let replyEvent):
                apply(replyEvent, to: reply.id, started: started, firstPiece: &firstPiece)
              case .timings(let timings):
                computerTimings = timings
              }
            }
          } catch {
            // With Automatic, a computer that drops before replying hands the reply to the iPhone.
            guard settings.values.replyLocation == .automatic, firstPiece == nil, !isStopping,
              !(error is CancellationError)
            else { throw error }
            computerState = .unreachable(error.localizedDescription)
            computerCheckedAt = .now
            chatNotice = "Lost the connection to your computer, so this reply ran on the iPhone."
            computer = nil
            generatingOnComputer = false
            try await streamOnDevice(
              options: options, history: history, contextLimit: contextLimit, prompt: prompt,
              image: image, maxReplyTokens: maxReplyTokens, webSearch: webSearch, replyID: reply.id,
              started: started, firstPiece: &firstPiece)
          }
        } else {
          try await streamOnDevice(
            options: options, history: history, contextLimit: contextLimit, prompt: prompt,
            image: image, maxReplyTokens: maxReplyTokens, webSearch: webSearch, replyID: reply.id,
            started: started, firstPiece: &firstPiece)
        }
      } catch {
        if !isStopping {
          // The engine's conversation may no longer match the chat, so rebuild it next time.
          activeConversation = nil
          updateMessage(reply.id) {
            $0.text = "Error: \(error.localizedDescription)"
            $0.isError = true
          }
        }
      }
      if isStopping {
        updateMessage(reply.id) { if $0.text.isEmpty { $0.text = "(stopped)" } }
      }

      monitor.cancel()
      let peaks = await monitor.value
      let counters: ReplyCounters
      if computer != nil {
        counters = ReplyCounters(
          contextTokens: nil,
          promptTokens: computerTimings?.promptTokens,
          replyTokens: computerTimings?.replyTokens,
          prefillTokensPerSecond: computerTimings?.prefillTokensPerSecond,
          decodeTokensPerSecond: computerTimings?.decodeTokensPerSecond)
      } else {
        counters = await device.replyCounters()
      }
      contextTokens = counters.contextTokens

      if messages.first(where: { $0.id == reply.id })?.isError == false {
        let stats = ReplyStats(
          producedBy: computer == nil ? deviceBackend : "My computer",
          promptTokens: counters.promptTokens,
          replyTokens: counters.replyTokens,
          prefillTokensPerSecond: counters.prefillTokensPerSecond,
          decodeTokensPerSecond: counters.decodeTokensPerSecond,
          timeToFirstToken: firstPiece?.inSeconds,
          totalSeconds: started.duration(to: .now).inSeconds,
          contextTokens: counters.contextTokens,
          contextLimit: computer?.status.context ?? contextLimit,
          peakMemoryBytes: peaks.memory,
          peakCPUPercent: peaks.cpuPercent,
          gpuMemoryBytes: DeviceMetrics.gpuMemory(),
          thermalState: ProcessInfo.processInfo.thermalState.label,
          wasStopped: isStopping)
        updateMessage(reply.id) { $0.stats = stats }
        totals.add(stats)
        try? await archive.saveTotals(totals)
      }

      openChat.updatedAt = Date()
      await save()
      isGenerating = false
      isStopping = false
      generatingOnComputer = false
      generationTask = nil
    }
  }

  /// Streams a reply from the model on this iPhone, starting a new engine conversation when the chat
  /// or its settings have changed.
  private func streamOnDevice(
    options: ConversationOptions, history: [ChatMessage], contextLimit: Int, prompt: String,
    image: PreparedImage?, maxReplyTokens: Int, webSearch: WebSearchConfig?,
    replyID: ChatMessage.ID, started: ContinuousClock.Instant, firstPiece: inout Duration?
  ) async throws {
    if activeConversation != options {
      activeConversation = nil
      let restored = try await device.startConversation(
        options, history: Self.historyTurns(history, contextSize: contextLimit))
      activeConversation = options
      if !restored {
        chatNotice =
          "Earlier messages didn't fit in the model's context, so it only sees your new message."
      }
    }
    let stream = try await device.stream(
      prompt, imageData: supportsImages ? image?.jpegData : nil,
      maxReplyTokens: maxReplyTokens > 0 ? maxReplyTokens : nil,
      webSearch: webSearch)
    for try await event in stream {
      apply(event, to: replyID, started: started, firstPiece: &firstPiece)
    }
  }

  /// Where this reply runs: your computer, or nil for this iPhone. With "My computer" a computer
  /// that can't be reached is an error; with "Automatic" the reply quietly falls back to the phone.
  private func computerRoute() async throws -> ComputerConnection? {
    let location = settings.values.replyLocation
    guard location != .iPhone else { return nil }
    guard let url = ComputerAddress.url(from: settings.values.computerAddress) else {
      computerState = .notConfigured
      if location == .computer { throw ComputerError.notConfigured }
      return nil
    }
    // Automatic doesn't sit through another timeout for a computer that just failed to answer.
    if location == .automatic, case .unreachable = computerState, let checked = computerCheckedAt,
      checked.duration(to: .now) < Self.unreachableRetryDelay
    {
      chatNotice = "Your computer isn't reachable, so this reply ran on the iPhone."
      return nil
    }
    do {
      guard network.isOnline else { throw ComputerError.offline }
      let token = ComputerTokenStore.read()
      let status = try await ComputerEngine.status(baseURL: url, token: token, timeout: 2)
      guard status.isReady else { throw ComputerError.notReady(status.modelServer ?? "starting") }
      computerState = .online(status)
      computerCheckedAt = .now
      return ComputerConnection(url: url, token: token, status: status)
    } catch {
      computerState = .unreachable(error.localizedDescription)
      computerCheckedAt = .now
      guard location == .automatic else { throw error }
      chatNotice = "Your computer didn't answer, so this reply ran on the iPhone."
      return nil
    }
  }

  private func apply(
    _ event: ReplyEvent, to replyID: ChatMessage.ID, started: ContinuousClock.Instant,
    firstPiece: inout Duration?
  ) {
    switch event {
    case .text(let piece):
      if firstPiece == nil { firstPiece = started.duration(to: .now) }
      updateMessage(replyID) { $0.text += piece }
    case .thinking(let piece):
      if firstPiece == nil { firstPiece = started.duration(to: .now) }
      updateMessage(replyID) { $0.thinking += piece }
    case .searching(let query):
      updateMessage(replyID) { $0.searchQueries = ($0.searchQueries ?? []) + [query] }
    case .sources(let sources):
      updateMessage(replyID) { $0.sources = ($0.sources ?? []) + sources }
    case .searchError(let message):
      chatNotice = "Web search failed: \(message)"
    case .memorySaved(let fact):
      memory.add(fact)
      updateMessage(replyID) { $0.savedMemories = ($0.savedMemories ?? []) + [fact] }
      // This conversation already knows the fact, so it shouldn't be rebuilt over it.
      activeConversation?.memories = memory.promptItems
    }
  }

  // MARK: - Housekeeping

  private func stopGeneration() async {
    guard let task = generationTask else { return }
    stop()
    await task.value
  }

  private func startNewChat() {
    speechInput.cancel()
    openChat = Chat(systemPrompt: settings.values.systemPrompt)
    images = [:]
    pendingImage = nil
    draft = ""
    editingMessageID = nil
    contextTokens = nil
    chatNotice = nil
    // The engine's conversation still holds the previous chat's turns.
    activeConversation = nil
  }

  /// Removes a message and everything after it. Returns the IDs of removed messages with photos.
  private func truncate(from id: ChatMessage.ID) -> [ChatMessage.ID] {
    guard let index = openChat.messages.firstIndex(where: { $0.id == id }) else { return [] }
    let removedImages = openChat.messages[index...].filter(\.hasImage).map(\.id)
    openChat.messages.removeSubrange(index...)
    for id in removedImages { images[id] = nil }
    // The engine still holds the removed turns, so the next send starts a fresh conversation.
    activeConversation = nil
    contextTokens = nil
    return removedImages
  }

  private func save() async {
    let snapshot = openChat
    guard !snapshot.messages.isEmpty else { return }
    // A failed write (most likely the phone locking mid-write) is retried by the next save.
    try? await archive.save(snapshot)
    savedChats.removeAll { $0.id == snapshot.id }
    savedChats.insert(snapshot, at: 0)
  }

  private func conversationOptions() -> ConversationOptions {
    let values = settings.values
    return ConversationOptions(
      systemPrompt: openChat.systemPrompt,
      sampler: values.useModelSamplerDefaults ? nil : values.sampler,
      thinking: values.thinkingEnabled && (modelDetails?.supportsThinking ?? false),
      webSearch: webSearchOn,
      memoryEnabled: values.memoryEnabled,
      memories: values.memoryEnabled ? memory.promptItems : [])
  }

  private func updateMessage(_ id: ChatMessage.ID, _ change: (inout ChatMessage) -> Void) {
    guard let index = openChat.messages.firstIndex(where: { $0.id == id }) else { return }
    change(&openChat.messages[index])
  }

  /// The most recent turns that fit in about half the context (roughly four characters per token),
  /// leaving room for the new message and its reply. Photos aren't re-sent; they're noted in text.
  private static func historyTurns(_ messages: [ChatMessage], contextSize: Int) -> [HistoryTurn] {
    var remaining = contextSize * 2
    var turns: [HistoryTurn] = []
    for message in messages.reversed() where !message.isError {
      let text =
        message.hasImage
        ? "(shared a photo) \(message.text)".trimmingCharacters(in: .whitespaces) : message.text
      guard !text.isEmpty else { continue }
      remaining -= text.count
      if remaining < 0 { break }
      turns.append(HistoryTurn(isUser: message.role == .user, text: text))
    }
    turns.reverse()
    // Chat templates expect the history to start with a user turn.
    while turns.first?.isUser == false { turns.removeFirst() }
    return turns
  }

  private static func title(for text: String) -> String {
    let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    guard !firstLine.isEmpty else { return "Photo" }
    return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
  }
}
