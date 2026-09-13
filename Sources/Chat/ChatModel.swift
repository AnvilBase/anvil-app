import CoreGraphics
import Foundation
import Observation

/// Everything the chat screens read and act on: the open chat, saved history, dictation, and
/// per-reply measurements.
///
/// It owns the engine running the model on this iPhone and is the only place that decides what
/// happens to a message.
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
  /// Bumped the instant a reply's first words arrive. A counter, not a flag, so two replies in a
  /// row register as two events rather than one unchanged value.
  private(set) var replyStarted = 0
  /// Bumped whenever a message of yours joins the chat. The screen watches it so it animates that
  /// one arrival and nothing else: opening a chat and streaming a reply change the transcript too,
  /// and neither should look like a message being sent.
  private(set) var messagesSent = 0
  private(set) var contextTokens: Int?
  private(set) var totals = UsageTotals()
  /// The past message being edited. Sending replaces it and everything after it.
  private(set) var editingMessageID: ChatMessage.ID?
  var draft = ""
  /// Which run of dictation the message field currently belongs to. See `endDictation`.
  private var dictationSession = 0
  var alertMessage: String?
  /// A line shown over the conversation for a moment and then taken away again. For a control
  /// pressed before it can do anything, where an alert would be far too much for something that
  /// sorts itself out on its own.
  private(set) var momentaryNotice: String?
  private var momentaryNoticeTask: Task<Void, Never>?

  let settings: SettingsStore
  /// Whether Anvil Pro is active. The settings it unlocks are stored either way and honoured only
  /// while this says so: `conversationOptions()` is where that is decided.
  let pro: ProAccess
  let network = NetworkStatus()
  let memory = MemoryStore()
  let speechInput = SpeechInput()
  let speechOutput = SpeechOutput()
  private let device = OnDeviceEngine()
  private let archive = ChatArchive()
  private var loadedModel: ModelFile?
  private var generationTask: Task<Void, Never>?
  /// How the engine's current conversation was created. nil means it no longer matches the open
  /// chat, so the next send rebuilds one from history.
  private var activeConversation: ConversationOptions?

  init(settings: SettingsStore, pro: ProAccess) {
    self.settings = settings
    self.pro = pro
    openChat = Chat(systemPrompt: settings.values.systemPrompt)
  }

  /// Replies read aloud, and the microphone open again when they finish. Pro, and on.
  var talkModeOn: Bool { pro.isUnlocked && settings.values.talkMode }

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
    if let abandoned = LoadAttempt.abandoned(), abandoned == options {
      if let reduced = options.afterRunningOutOfMemory() {
        // Backed off quietly. Saying "the model ran this iPhone out of memory, so image input is
        // off" reads as the app having gone wrong on the one screen where nothing has: the model
        // loads, and what changed is sitting in Settings › Model for anyone who looks.
        options = reduced
        settings.values.engine = reduced
        settings.save()
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
      notice = result.notice
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
    speechOutput.stop()
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

  // MARK: - Sending

  /// What the send button calls. It is pressed before the model is ready more often than you would
  /// think — the first load of a several-gigabyte model is slow — and a button that looks pressable
  /// and then does nothing at all reads as broken. So it answers.
  func sendOrSayWhyNot() {
    guard !canSend else {
      send()
      return
    }
    // Generating and preparing an image both show what they are doing already; only waiting on the
    // model looks like nothing happening.
    guard loadState == .loading else { return }
    showMomentarily("Loading the model. The first time takes a minute.")
  }

  private func showMomentarily(_ message: String) {
    momentaryNoticeTask?.cancel()
    momentaryNotice = message
    momentaryNoticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3.5))
      guard !Task.isCancelled else { return }
      self?.momentaryNotice = nil
    }
  }

  func send() {
    guard canSend else { return }
    speechOutput.stop()
    // The message has gone, so the microphone's work is done. Without this the recogniser carries
    // on — and its next result, or the final one still owed from a stop a moment ago, lands in the
    // field that has just been emptied, which is the text you thought you had sent sitting there
    // again.
    endDictation()
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
  ///
  /// Stopping is not the same as ending it: tapping stop still wants the last words the recogniser
  /// owes you, so the field keeps filling until they arrive. Sending is what ends it — see
  /// `endDictation`.
  func toggleDictation(autoSend: Bool? = nil) {
    if speechInput.isActive {
      speechInput.stop()
      return
    }
    // Tapping the microphone while a reply is being read is asking for a turn: the reply stops.
    speechOutput.stop()
    guard loadState == .ready, !isGenerating else { return }
    let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    // Talk mode always sends when you stop talking, whoever started the microphone; that is what
    // makes it hands-free.
    let autoSend = autoSend ?? (talkModeOn || settings.values.autoSendVoice)
    let session = dictationSession
    Task {
      do {
        try await speechInput.start(
          stopAfterSilence: autoSend,
          onUpdate: { [weak self] transcript in
            guard let self, session == dictationSession else { return }
            draft = existing.isEmpty ? transcript : "\(existing) \(transcript)"
          },
          onFinish: { [weak self] transcript in
            guard let self, session == dictationSession, autoSend, !transcript.isEmpty else {
              return
            }
            send()
          })
      } catch {
        alertMessage = error.localizedDescription
      }
    }
  }

  /// Ends dictation and disowns the session that was running, so nothing it still has in flight can
  /// write to the field afterwards.
  ///
  /// Stopping the recogniser is not enough on its own. A result already on its way from the audio
  /// thread will be delivered whatever happens here, and the closure that handles it captured a
  /// field that was full when dictation began; the counter is what tells it the field has moved on
  /// without it.
  private func endDictation() {
    dictationSession &+= 1
    speechInput.cancel()
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
    speechOutput.stop()
    guard let task = generationTask, !isStopping else { return }
    isStopping = true
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

  /// Adds your message and streams the reply to it.
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
    messagesSent += 1
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

      do {
        try await streamOnDevice(
          options: options, history: history, contextLimit: contextLimit, prompt: prompt,
          image: image, maxReplyTokens: maxReplyTokens, webSearch: webSearch, replyID: reply.id,
          started: started, firstPiece: &firstPiece)
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
      let counters = await device.replyCounters()
      contextTokens = counters.contextTokens

      if messages.first(where: { $0.id == reply.id })?.isError == false {
        let stats = ReplyStats(
          producedBy: deviceBackend,
          promptTokens: counters.promptTokens,
          replyTokens: counters.replyTokens,
          prefillTokensPerSecond: counters.prefillTokensPerSecond,
          decodeTokensPerSecond: counters.decodeTokensPerSecond,
          timeToFirstToken: firstPiece?.inSeconds,
          totalSeconds: started.duration(to: .now).inSeconds,
          contextTokens: counters.contextTokens,
          contextLimit: contextLimit,
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
      let wasStopped = isStopping
      isGenerating = false
      isStopping = false
      generationTask = nil

      // Talk mode: read the reply, then listen for the next thing. Not a stopped reply — stopping
      // it was the point — and not an error, which is for reading, not hearing.
      if talkModeOn, !wasStopped,
        let reply = messages.first(where: { $0.id == reply.id }), !reply.isError, !reply.text.isEmpty
      {
        Task { await speakThenListen(reply.text) }
      }
    }
  }

  /// One turn of talk mode. The reply is spoken in full unless something interrupts it — sending,
  /// stopping, or tapping the microphone all do — and only a reply that finished on its own opens
  /// the microphone again, so an interruption is the end of the turn and not the start of another.
  private func speakThenListen(_ text: String) async {
    await speechOutput.speak(Self.spokenForm(of: text))
    guard talkModeOn, loadState == .ready, !isGenerating, !speechInput.isActive,
      draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    toggleDictation(autoSend: true)
  }

  /// A reply as it should be heard rather than seen: code blocks out, markdown marks off, citation
  /// numbers gone, links as their text.
  static func spokenForm(of markdown: String) -> String {
    var text = markdown
    text = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"[`*_#>]+"#, with: "", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

  private func apply(
    _ event: ReplyEvent, to replyID: ChatMessage.ID, started: ContinuousClock.Instant,
    firstPiece: inout Duration?
  ) {
    switch event {
    case .text(let piece):
      if firstPiece == nil {
        firstPiece = started.duration(to: .now)
        replyStarted += 1
      }
      updateMessage(replyID) { $0.text += piece }
    case .thinking(let piece):
      if firstPiece == nil {
        firstPiece = started.duration(to: .now)
        replyStarted += 1
      }
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
    endDictation()
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

  /// What the model is told and how it samples. The prompt a chat carries, custom sampling and
  /// thinking are Anvil Pro: without it the chat runs on the default prompt and the model's own
  /// sampling, whatever the settings file says — the file is where a Pro subscriber's choices
  /// wait, not where Pro is decided.
  private func conversationOptions() -> ConversationOptions {
    let values = settings.values
    let isPro = pro.isUnlocked
    return ConversationOptions(
      systemPrompt: isPro ? openChat.systemPrompt : AppSettings.defaultSystemPrompt,
      sampler: isPro && !values.useModelSamplerDefaults ? values.sampler : nil,
      thinking: isPro && values.thinkingEnabled && (modelDetails?.supportsThinking ?? false),
      webSearch: webSearchOn,
      memoryEnabled: values.memoryEnabled,
      memories: values.memoryEnabled ? memory.promptItems : [],
      spokenReplies: talkModeOn)
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
