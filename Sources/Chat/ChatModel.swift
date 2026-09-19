import CoreGraphics
import AVFoundation
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
  /// A file waiting to go with the next message.
  private(set) var pendingFile: FileAttachment?
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
  private let dream = DreamEngine()
  private let archive = ChatArchive()
  private var loadedModel: ModelFile?
  /// Anvil Dream, when it is installed and Pro is active. Handed in by the chat screen from the
  /// library, the way the text model is.
  private(set) var imageModel: ModelFile?
  private var generationTask: Task<Void, Never>?
  /// How the engine's current conversation was created. nil means it no longer matches the open
  /// chat, so the next send rebuilds one from history.
  private var activeConversation: ConversationOptions?

  init(settings: SettingsStore, pro: ProAccess) {
    self.settings = settings
    self.pro = pro
    openChat = Chat(systemPrompt: settings.systemPrompt)
  }

  /// Replies read aloud, and the microphone open again when they finish. Pro, and on.

  /// Voice mode: the conversation held out loud, over the chat, until it is closed. Not a setting
  /// and not remembered; it is a thing you are doing, and it ends when you stop.
  private(set) var voiceModeOn = false

  enum VoicePhase: Equatable {
    case idle
    case listening
    case thinking
    case speaking
  }

  /// What voice mode is doing at this moment, for the screen to say and shape itself around.
  var voicePhase: VoicePhase {
    if speechOutput.isSpeaking { return .speaking }
    if isGenerating { return .thinking }
    if speechInput.isActive { return .listening }
    return .idle
  }

  /// Whether the model in use is Anvil Raw — the Pro text model, the one with its refusals
  /// removed. Only with it does the app make a picture without asking the model, follow one up,
  /// or answer a refusal with the picture. Anvil Core keeps its own judgement: what it declines,
  /// it declines.
  var isUnrestricted: Bool { loadedModel?.isPro == true && loadedModel?.kind == .text }

  /// Whether a reply can come with a picture: Anvil Dream is on the phone and switched on, and Pro
  /// is active. The library only ever hands over a Pro model while Pro is active, but this is
  /// decided in one place, so it is asked again here. Every way a picture gets made asks this, so
  /// the switch in Settings › Models turns off all of them at once.
  var canGenerateImages: Bool {
    pro.isUnlocked && imageModel != nil && settings.imageGenerationEnabled
  }

  /// A picture the model asked for during its reply, to be made once the reply is done. See
  /// `EngineEvent.imageDeferred`.
  private var deferredPicture: String?

  /// Whether a picture has been made since the app was launched. The first one loads the whole
  /// pipeline from disk before it can begin, which is most of a minute on some phones, and a
  /// wait with no word about it reads as something gone wrong. So the first one, once it has
  /// gone on for a while, says why.
  private var hasMadePictureSinceLaunch = false
  /// True while the first picture of this launch has been going for long enough to deserve a
  /// word about it. The screen shows the word; this decides when.
  private(set) var firstPictureIsTakingItsTime = false
  private var firstPictureNote: Task<Void, Never>?
  /// Where the picture being made has got to, from Anvil Dream, for the screen to draw under
  /// "Making the picture…". Nil when no picture is being made.
  private(set) var pictureStage: PictureStage?
  /// How long the first picture goes before the screen says the first one is slower.
  private static let firstPictureNoteAfter: Duration = .seconds(10)

  /// Whether this phone has to choose between the chat model and the picture model. Both
  /// resident is over 7 GB — Anvil Raw and Anvil Dream together — and a phone with 8 has
  /// nothing left for iOS. Twelve is the line below which they take turns.
  private static var pictureNeedsChatModelSetDown: Bool {
    ProcessInfo.processInfo.physicalMemory < 12_000_000_000
  }

  /// Called as a picture starts, from whichever path starts it.
  func pictureBegan() {
    guard !hasMadePictureSinceLaunch else { return }
    firstPictureNote?.cancel()
    firstPictureNote = Task { [weak self] in
      try? await Task.sleep(for: Self.firstPictureNoteAfter)
      guard let self, !Task.isCancelled else { return }
      firstPictureIsTakingItsTime = true
    }
  }

  /// Called as a picture finishes, however it finished.
  func pictureEnded() {
    hasMadePictureSinceLaunch = true
    firstPictureNote?.cancel()
    firstPictureNote = nil
    firstPictureIsTakingItsTime = false
    pictureStage = nil
  }

  /// What Anvil Dream is handed to report with: each stage lands on the main actor and the
  /// screen redraws its line.
  private var pictureProgress: @Sendable (PictureStage) -> Void {
    { [weak self] stage in Task { @MainActor in self?.pictureStage = stage } }
  }

  /// What to do when the picture model turns out to be damaged: the library looks at the folder
  /// again, throws it away, and the chat stops being offered pictures until it is back. Set by the
  /// chat screen, which is where the chat and the library meet.
  var repairImageModel: (() async -> Void)?

  /// Set when a message asked for a picture and Pro isn't active: the chat screen shows the Pro
  /// page, and clears this when it goes. See `ImageRequest` for what counts as asking.
  var showingPro = false

  // MARK: - What the screens ask

  var messages: [ChatMessage] { openChat.messages }

  var supportsImages: Bool { modelDetails?.supportsImages ?? false }

  /// Whether this build carries a Brave Search key (Config/Local.xcconfig).

  var isOffline: Bool { !network.isOnline }

  /// Whether replies can search right now. Your preference is kept while offline, and search comes
  /// back on by itself when the connection returns.
  var webSearchOn: Bool { settings.webSearchEnabled && network.isOnline }

  /// A model is coming down. The chat waits for it: the engine is about to be swapped
  /// under the conversation — Anvil Pro replaces Anvil Core when it lands — and a reply
  /// begun on one model and finished on another is not a reply anyone asked for.
  /// Set by the chat screen, which is where the library and the chat meet.
  var isInstallingModel = false

  var canSend: Bool {
    loadState == .ready && !isGenerating && !isPreparingImage && !isInstallingModel
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil
        || pendingFile != nil)
  }

  /// True when engine settings have changed since the model was loaded.
  var needsReload: Bool {
    loadedEngineOptions.map { $0 != settings.engine } ?? false
  }

  /// Replies that came back errors, one after another. One is a bad reply — a prompt the model
  /// choked on, a tool that didn't answer — and nothing to rebuild an engine over. Several running
  /// is the engine itself.
  private var failedReplies = 0
  private static let failuresBeforeReload = 2

  /// When the model was last put back together to get out of trouble, so a reload that doesn't fix
  /// anything can't become a reload every time the app is glanced at.
  private var lastTroubleReload: ContinuousClock.Instant?
  private static let troubleReloadInterval: Duration = .seconds(30)

  /// Whether the chat is stuck in a way a reload could plausibly get it out of: the model never
  /// loaded, or reply after reply is coming back an error.
  private var isInTrouble: Bool {
    if case .failed = loadState { return true }
    return failedReplies >= Self.failuresBeforeReload
  }

  /// Loads the model again when it needs it.
  ///
  /// Settings › Models has a Reload model button for this too, for the times only a person can
  /// tell that now is the time. It is not the ordinary way: the app knows when its engine is no
  /// longer the one the settings describe, when the load failed, and when reply after reply comes
  /// back an error, and does the reload itself — when Settings closes, when the app comes back to
  /// the screen, and after a reply has failed twice running.
  func reloadIfNeeded() async {
    guard loadedModel != nil else { return }
    // Settings the model wasn't loaded with. Not a symptom of anything going wrong — it is the
    // change being applied — so it happens at once and as often as it is asked for.
    if needsReload {
      lastTroubleReload = nil
      failedReplies = 0
      await reloadModel()
      return
    }
    // Trouble, which is the other thing, and has to be rationed: the same load fails the same way,
    // and the point of waiting is to give whatever was in the way — memory, most often — time to
    // stop being in the way.
    guard isInTrouble else { return }
    if let last = lastTroubleReload, last.duration(to: .now) < Self.troubleReloadInterval { return }
    lastTroubleReload = .now
    failedReplies = 0
    await reloadModel()
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
    var options = settings.engine
    if let abandoned = LoadAttempt.abandoned(), abandoned == options {
      if let reduced = options.afterRunningOutOfMemory() {
        // Backed off quietly. Saying "the model ran this iPhone out of memory, so the context is
        // smaller" reads as the app having gone wrong on the one screen where nothing has: the
        // model loads, and what changed is sitting in Settings › Models for anyone who looks.
        options = reduced
        settings.engine = reduced
        settings.save()
      } else {
        LoadAttempt.succeeded()
        modelDetails = nil
        loadedEngineOptions = nil
        loadState = .failed(
          "This model needs more memory than iOS will give the app, even with the smallest context "
            + "and the CPU. A smaller model is the way forward.")
        return
      }
    }
    // Nothing to load. Said here rather than left to the engine, which would try each backend in
    // turn against a file that isn't there.
    guard FileManager.default.fileExists(atPath: model.url.path) else {
      modelDetails = nil
      loadedEngineOptions = nil
      loadState = .failed("No model is installed. Download one in Settings › Models.")
      return
    }
    LoadAttempt.begin(options)

    do {
      let result = try await device.load(model: model, options: options)
      LoadAttempt.succeeded()
      guard loadedModel == model else { return }  // A newer import superseded this load.
      modelDetails = result.details
      loadedEngineOptions = options
      notice = result.notice
      loadState = .ready
    } catch {
      LoadAttempt.succeeded()
      guard loadedModel == model else { return }
      modelDetails = nil
      loadedEngineOptions = nil
      loadState = .failed(error.localizedDescription)
    }
  }

  func reloadModel() async {
    guard let loadedModel else { return }
    await load(loadedModel, force: true)
  }

  /// The image model to make pictures with, or none. A change lets go of whatever Anvil Dream had
  /// loaded; the next reply picks up the new one, or the tool, on its own.
  func setImageModel(_ model: ModelFile?) {
    guard model != imageModel else { return }
    imageModel = model
    Task { await dream.unload() }
  }

  /// Lets go of Anvil Dream's models, for before the folder they are in is deleted.
  func unloadImageModel() async {
    await dream.unload()
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
    await dream.unload()
  }

  func setWebSearch(_ enabled: Bool) {
    settings.webSearchEnabled = enabled
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
    showMomentarily("Warming up model")
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
    // A message that asks for a picture, read from its words — see `ImageRequest` — rather than
    // decided by the model. Where one can be made it is made straight away, below. Where none
    // can be: without Pro the message stays in the field and the Pro page opens, so what was
    // asked for is one tap away and the words are still there to send once it is; with Pro and
    // no Anvil Dream, or Anvil Dream switched off, the message goes, and a notice says where the
    // download, or the switch, is.
    let typedNow = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    // A message with something attached — a photo or a file — is about the attachment, never a
    // request for a picture: "make this image brighter" is about the photo. It goes to the text
    // model, with Anvil Dream kept out of that turn (see `submit`).
    let hasAttachment = pendingImage != nil || pendingFile != nil
    // With Anvil Pro, a picture asked for is made without asking the model, and "make it
    // darker" or "another one" after a picture is the picture changed. With Anvil Core the
    // model is asked, through its tool, and decides for itself.
    let makesDirectly = canGenerateImages && isUnrestricted
    // "Generate a banana" names no picture and is one all the same. Read as the ask it is where
    // the picture can be made straight away: asked of the model instead, a small one answered
    // "Generated a banana!" and made nothing, and a sentence about a picture is worse than the
    // picture with no sentence.
    let asksForPicture =
      !hasAttachment
      && (ImageRequest.isAsking(typedNow) || (makesDirectly && ImageRequest.probablyAsking(typedNow)))
    let followsPicture =
      !hasAttachment && !asksForPicture && makesDirectly && lastPicturePrompt != nil
      && ImageRequest.isFollowUp(typedNow)
    if asksForPicture, !canGenerateImages {
      if pro.isUnlocked {
        chatNotice =
          imageModel == nil
          ? "Download an image model in Settings › Image to make pictures."
          : "Image generation is off. Turn it on in Settings › Image to make pictures."
      } else {
        showingPro = true
        return
      }
    }
    speechOutput.stop()
    // The message has gone, so the microphone's work is done. Without this the recogniser carries
    // on — and its next result, or the final one still owed from a stop a moment ago, lands in the
    // field that has just been emptied, which is the text you thought you had sent sitting there
    // again.
    endDictation()
    let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let image = pendingImage
    let file = pendingFile
    draft = ""
    pendingImage = nil
    pendingFile = nil

    var removedImageIDs: [ChatMessage.ID] = []
    if let editingMessageID {
      removedImageIDs = truncate(from: editingMessageID)
      self.editingMessageID = nil
    }
    if asksForPicture, makesDirectly {
      submitPicture(
        typed, description: ImageRequest.description(in: typed), removedImageIDs: removedImageIDs)
    } else if followsPicture, let previous = lastPicturePrompt {
      submitPicture(
        typed, description: ImageRequest.followUpDescription(typed, after: previous),
        removedImageIDs: removedImageIDs)
    } else {
      submit(typed, image: image, file: file, removedImageIDs: removedImageIDs)
    }
  }

  /// What the last picture in the chat was made from, if the reply before this message was one.
  private var lastPicturePrompt: String? {
    guard let last = openChat.messages.last, last.role == .assistant, last.hasImage else { return nil }
    return last.imagePrompt
  }

  /// Starts or stops dictation. Speech is recognized on this iPhone and typed into the message
  /// field; with "send when you stop talking" on, the message goes as soon as you pause.
  ///
  /// Stopping is not the same as ending it: tapping stop still wants the last words the recogniser
  /// owes you, so the field keeps filling until they arrive. Sending is what ends it — see
  /// `endDictation`.
  func toggleDictation(autoSend: Bool? = nil) {
    // In voice mode the microphone is voice mode's, and stopping it on its own only has voice mode
    // open it again. Its stop is the way out instead, as the button in the bar is.
    if voiceModeOn, speechInput.isActive {
      endVoiceMode()
      return
    }
    if speechInput.isActive {
      speechInput.stop()
      return
    }
    // Tapping the microphone while a reply is being read is asking for a turn: the reply stops.
    speechOutput.stop()
    guard loadState == .ready, !isGenerating else { return }
    let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let autoSend = autoSend ?? settings.autoSendVoice
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

  // MARK: - Voice mode

  /// The button in the bar: opens voice mode, or closes it if it is open.
  func toggleVoiceMode() {
    if voiceModeOn { endVoiceMode() } else { startVoiceMode() }
  }

  /// Opens voice mode and starts listening. Pro's, like talk mode: without it the paywall opens.
  func startVoiceMode() {
    guard pro.isUnlocked else {
      showingPro = true
      return
    }
    guard loadState == .ready, !voiceModeOn else { return }
    speechOutput.stop()
    endDictation()
    voiceModeOn = true
    speechOutput.sharesAudioSession = true
    listenInVoiceMode()
  }

  /// Closes voice mode: the voice stops, the microphone closes, and whatever was half-said is
  /// left in the field, where it can be sent or cleared by hand.
  func endVoiceMode() {
    guard voiceModeOn else { return }
    voiceModeOn = false
    speechOutput.stop()
    speechOutput.sharesAudioSession = false
    endDictation()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// The circle, tapped: a reply being read is cut off and the microphone opens for your turn;
  /// listening, it stops and sends what it heard; idle, it listens.
  func tapVoiceCircle() {
    guard voiceModeOn else { return }
    if speechOutput.isSpeaking {
      speechOutput.stop()
      listenInVoiceMode()
    } else if speechInput.isActive {
      speechInput.stop()
    } else if !isGenerating {
      listenInVoiceMode()
    }
  }

  /// Opens the microphone for a turn. It stays open until words arrive; from then a pause ends
  /// the turn and sends it. Never while a reply is being read: the phone would hear its own voice
  /// and answer itself. Talking over a reply is a tap on the circle.
  private func listenInVoiceMode() {
    guard voiceModeOn, loadState == .ready, !speechInput.isActive, !speechOutput.isSpeaking else {
      return
    }
    let session = dictationSession
    var armed = false
    Task {
      do {
        try await speechInput.start(
          stopAfterSilence: false, sharedSession: true,
          onUpdate: { [weak self] transcript in
            guard let self, session == dictationSession else { return }
            draft = transcript
            if !armed {
              armed = true
              speechInput.armSilenceStop()
            }
          },
          onFinish: { [weak self] transcript in
            guard let self, session == dictationSession, voiceModeOn else { return }
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              // The recogniser gave up before anyone spoke. Open it again, unless the turn has
              // moved on without it.
              if !isGenerating, !speechOutput.isSpeaking { listenInVoiceMode() }
            } else {
              send()
            }
          })
      } catch {
        alertMessage = error.localizedDescription
        endVoiceMode()
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

  /// True for a message of yours, when the chat is free to take it again.
  func canResend(_ id: ChatMessage.ID) -> Bool {
    guard loadState == .ready, !isGenerating, !isPreparingImage, editingMessageID == nil,
      let message = openChat.messages.first(where: { $0.id == id }), message.role == .user
    else { return false }
    return !message.text.isEmpty || message.hasImage || message.attachment != nil
  }

  /// Sends a past message of yours again, as it was — words, photo and file — as a new turn at
  /// the end of the chat. Nothing is replaced: that is what editing is for. It goes through
  /// `send` like a message typed now, so a request for a picture is a picture again.
  func resend(_ id: ChatMessage.ID) {
    guard canResend(id), let message = openChat.messages.first(where: { $0.id == id }) else { return }
    let chatID = openChat.id
    isPreparingImage = message.hasImage
    Task {
      var image: PreparedImage?
      if message.hasImage, let preview = images[id],
        let data = await archive.loadImage(chatID: chatID, messageID: id)
      {
        image = PreparedImage(jpegData: data, preview: preview)
      }
      isPreparingImage = false
      guard openChat.id == chatID, canResend(id) else { return }
      draft = message.text
      pendingImage = image
      pendingFile = message.attachment
      send()
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
    // The file goes again with the edited words, unless it is taken off.
    pendingFile = message.attachment

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
    pendingFile = nil
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
    let deleted = await archive.purge(olderThanDays: settings.historyRetentionDays)
    if deleted.contains(openChat.id), !isGenerating { startNewChat() }
    savedChats = await archive.loadAll()
  }

  /// Clears the chat now, in the same frame — the drawer starts closing in this same event, and
  /// the empty page has to be there for the first frame of the slide, riding it, rather than
  /// arriving a tick later over a page already on the move. Only a reply still being written makes
  /// this wait: it has to be stopped before the chat it belongs to goes.
  func newChat() {
    guard generationTask != nil else {
      startNewChat()
      return
    }
    Task {
      await stopGeneration()
      startNewChat()
    }
  }

  /// Opens a saved chat: its messages now, in this frame, for the same reason `newChat` clears
  /// in this frame; its photos as they load.
  func open(_ id: Chat.ID) {
    guard id != openChat.id, let saved = savedChats.first(where: { $0.id == id }) else { return }
    guard generationTask != nil else {
      startNewChat()
      openChat = saved
      Task { await loadImages(of: saved) }
      return
    }
    Task {
      await stopGeneration()
      guard id != openChat.id else { return }
      startNewChat()
      openChat = saved
      await loadImages(of: saved)
    }
  }

  private func loadImages(of saved: Chat) async {
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
    // The open chat goes now, in this frame, as in `newChat`; the archive follows.
    if generationTask == nil { startNewChat() }
    Task {
      if generationTask != nil {
        await stopGeneration()
        startNewChat()
      }
      do {
        try await archive.deleteAll()
        savedChats = []
      } catch {
        alertMessage = "Couldn't delete chats: \(error.localizedDescription)"
      }
    }
  }

  /// Saves settings and applies them — the parts that need no more than saving, and then, if the
  /// engine was given new instructions while the sheet was open, the model itself.
  func settingsDidClose() async {
    settings.save()
    if openChat.messages.isEmpty { openChat.systemPrompt = settings.systemPrompt }
    await purgeExpiredChats()
    await reloadIfNeeded()
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

  // MARK: - Files

  /// Reads a picked file into the next message. Off the main thread: a PDF can take a moment.
  func attachFile(_ url: URL) async {
    do {
      pendingFile = try await Task.detached(priority: .userInitiated) { try FileReading.read(url) }.value
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  func removePendingFile() {
    pendingFile = nil
  }

  func removePendingImage() {
    pendingImage = nil
  }

  // MARK: - Writing a reply

  /// Makes the picture itself, without asking the text model whether to. A model taught to refuse
  /// refuses pictures too, and a picture asked for on the user's own phone is theirs to have: the
  /// ask is read from the words, what is left of them is the description, and Anvil Dream is
  /// called straight. The reply is the picture under a caption. The text model isn't consulted,
  /// so there is no one to say no.
  private func submitPicture(
    _ typed: String, description: String, removedImageIDs: [ChatMessage.ID]
  ) {
    guard let imageModel else { return }
    if openChat.messages.isEmpty {
      openChat.systemPrompt = settings.systemPrompt
      openChat.title = Self.title(for: typed)
    }
    let user = ChatMessage(role: .user, text: typed)
    let reply = ChatMessage(role: .assistant, text: "", imagePrompt: description)
    openChat.messages.append(contentsOf: [user, reply])
    openChat.updatedAt = Date()
    messagesSent += 1
    isGenerating = true
    chatNotice = nil
    let chatID = openChat.id

    generationTask = Task {
      for id in removedImageIDs {
        await archive.deleteImage(chatID: chatID, messageID: id)
      }
      await save()
      await makePicture(description, into: reply.id, chatID: chatID, with: imageModel)
      // The engine's conversation never saw this turn; the next send rebuilds it from history.
      activeConversation = nil
      openChat.updatedAt = Date()
      await save()
      isGenerating = false
      isStopping = false
      generationTask = nil
    }
  }

  /// Makes the picture and puts it in the reply, under a caption; or, failing, says why there.
  private func makePicture(
    _ description: String, into replyID: ChatMessage.ID, chatID: UUID, with imageModel: ModelFile
  ) async {
    updateMessage(replyID) { $0.imagePrompt = description }
    pictureBegan()
    defer { pictureEnded() }
    // On a phone that can't hold both, the chat model is set down for the picture and picked
    // up again after. Its conversation is rebuilt from history on the next message, which
    // costs a moment then; the alternative was the phone thrashing for minutes, or the app
    // killed with 6 GB resident — both of which happened.
    let setDownChatModel = Self.pictureNeedsChatModelSetDown
    if setDownChatModel {
      activeConversation = nil
      await device.unload()
    }
    defer {
      if setDownChatModel, let loadedModel {
        // Turns means turns: the picture model is set down before the chat model is picked
        // up, not kept warm for the next picture under it. Kept, it was 3 GB still resident
        // while 4 GB of chat model came back — over what an 8 GB phone will give one app,
        // and the app was killed the moment the picture was done.
        Task {
          await self.dream.unload()
          await self.load(loadedModel, force: true)
        }
      }
    }
    do {
      let image = try await dream.generate(description, from: imageModel, progress: pictureProgress)
      guard let data = ImageProcessing.jpegData(image) else { throw DreamEngine.Failure.noOutput }
      if let decoded = ImageProcessing.decode(data) { images[replyID] = decoded }
      updateMessage(replyID) {
        $0.hasImage = true
        $0.text = Self.caption(for: description)
        $0.isError = false
      }
      replyStarted += 1
      try? await archive.saveImage(data, chatID: chatID, messageID: replyID)
    } catch {
      updateMessage(replyID) {
        $0.imagePrompt = nil
        $0.text = "Couldn't make the picture: \(error.localizedDescription)"
        $0.isError = true
      }
      // Whatever went wrong, the library looks at the folder again. Looking is cheap — it reads
      // sizes and one small file — and it only throws away a folder that is actually not a
      // model, so a picture that failed for some passing reason costs nothing. But a folder
      // that is damaged in a way the engine reported as something else, or that Core ML
      // refused rather than the tokenizer, is found here rather than offered over and over.
      await repairImageModel?()
    }
  }

  /// The line under a picture: the prompt the image model was given, word for word, and
  /// nothing else — no sentence from the chat model about it, no rewording. What was sent is
  /// what is shown.
  private static func caption(for description: String) -> String {
    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Here it is." : trimmed
  }

  /// Adds your message and streams the reply to it.
  private func submit(
    _ typed: String, image: PreparedImage?, file: FileAttachment? = nil,
    removedImageIDs: [ChatMessage.ID]
  ) {
    if openChat.messages.isEmpty {
      // An empty chat picks up the latest system prompt from Settings.
      openChat.systemPrompt = settings.systemPrompt
      openChat.title = Self.title(for: typed.isEmpty ? (file?.name ?? "") : typed)
    }

    let history = openChat.messages
    let user = ChatMessage(role: .user, text: typed, hasImage: image != nil, attachment: file)
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
        apiKey: AppSecrets.braveSearchAPIKey, resultCount: settings.webSearchResultCount)
      : nil
    var options = conversationOptions()
    // Anvil Dream stays out of a turn that carries a photo or a file: the message is about what
    // was attached, and a model handed a picture tool beside a picture reaches for it. Without the
    // tool for this turn it can only answer. A change of options restarts the engine's
    // conversation from history, the way switching web search does.
    if image != nil || file != nil { options.imageGeneration = false }
    // With only a photo attached, give the model something to do with it. A file goes ahead of
    // the words, named and fenced, with the same standing question when there are none.
    let basePrompt = user.attachment != nil
      ? user.promptText : (typed.isEmpty ? "Describe this image." : typed)
    // Models keep answering the way they already have in a chat, so say when search was switched on
    // or off since the last reply (or is on in a chat being reopened). Only the model sees this.
    let searchChanged = activeConversation.map { $0.webSearch != options.webSearch } ?? options.webSearch
    let searchNote =
      history.isEmpty || !searchChanged
      ? nil : PromptBuilder.searchChangeNote(webSearchOn: options.webSearch)
    let prompt = searchNote.map { "\($0)\n\n\(basePrompt)" } ?? basePrompt
    let contextLimit = modelDetails?.contextSize ?? settings.engine.contextSize
    let maxReplyTokens = settings.maxReplyTokens
    let deviceBackend = modelDetails?.backend ?? "Unknown"
    let chatID = openChat.id
    // Anvil Dream, for this reply, if it can be used: the picture comes back as a JPEG, the way a
    // photo goes in, so it is kept with the chat the same way.
    let imageGenerator: (@Sendable (String) async throws -> Data)?
    if options.imageGeneration, let imageModel {
      let dream = dream
      let progress = pictureProgress
      imageGenerator = { [weak self] prompt in
        await MainActor.run { self?.pictureBegan() }
        defer { Task { @MainActor in self?.pictureEnded() } }
        let image = try await dream.generate(prompt, from: imageModel, progress: progress)
        guard let data = ImageProcessing.jpegData(image) else { throw DreamEngine.Failure.noOutput }
        return data
      }
    } else {
      imageGenerator = nil
    }

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
          image: image, maxReplyTokens: maxReplyTokens, webSearch: webSearch,
          imageGenerator: imageGenerator, replyID: reply.id, started: started,
          firstPiece: &firstPiece)
        failedReplies = 0
      } catch {
        if isStopping {
          // Stop was pressed; the reply is marked below.
        } else if case OnDeviceEngine.EngineError.cancelled = error {
          // Cut short by the engine rather than by Stop — iOS took the GPU away, most likely,
          // because the app left the screen mid-reply. Not a fault in the words so far, which
          // stay; the notice says what happened, and the next message goes again as normal.
          activeConversation = nil
          updateMessage(reply.id) { if $0.text.isEmpty { $0.text = "(stopped)" } }
          chatNotice = "The reply was cut short. Send the message again to continue."
        } else {
          // The engine's conversation may no longer match the chat, so rebuild it next time.
          activeConversation = nil
          failedReplies += 1
          updateMessage(reply.id) {
            $0.text = "Error: \(error.localizedDescription)"
            $0.isError = true
          }
        }
      }
      if isStopping {
        updateMessage(reply.id) { if $0.text.isEmpty { $0.text = "(stopped)" } }
      }

      // The picture the model asked for on the way, now that the words are in.
      if !isStopping, let prompt = deferredPicture, let imageModel {
        deferredPicture = nil
        await makePicture(prompt, into: reply.id, chatID: chatID, with: imageModel)
        activeConversation = nil
      }
      deferredPicture = nil

      // The last word on pictures, with Anvil Pro. A message that mentioned one, put some way
      // the words above didn't catch, and a model that answered by declining — or by saying it
      // had made one, and making nothing: the picture is made anyway, and its caption takes the
      // place of the words. Pro's no is not the app's, and neither is its "done"; Core's are.
      if !isStopping, canGenerateImages, isUnrestricted, image == nil, file == nil, let imageModel,
        ImageRequest.mightBeAsking(typed),
        let written = messages.first(where: { $0.id == reply.id }),
        !written.hasImage, written.imagePrompt == nil, !written.isError,
        ImageRequest.looksLikeRefusal(written.text) || ImageRequest.claimsPicture(written.text)
      {
        await makePicture(
          ImageRequest.description(in: typed), into: reply.id, chatID: chatID, with: imageModel)
        // The engine's conversation holds the refusal; the next send rebuilds it from history.
        activeConversation = nil
      }

      // A refusal from the free model, without Pro: the Pro page comes up over the reply, since
      // what was declined is what Anvil Raw is for. The reply stays — the page is over it, and
      // Not now puts it away — and only without Pro: with it, Raw is a download away in Settings
      // and the page has nothing to sell.
      if !isStopping, !pro.isUnlocked, !isUnrestricted,
        let written = messages.first(where: { $0.id == reply.id }),
        !written.isError, ImageRequest.looksLikeRefusal(written.text)
      {
        showingPro = true
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

      // Voice mode: read the reply, then listen for the next thing. Not a stopped reply —
      // stopping it was the point — and not an error, which is for reading, not hearing.
      if voiceModeOn, !wasStopped,
        let reply = messages.first(where: { $0.id == reply.id }), !reply.isError, !reply.text.isEmpty
      {
        Task { await speakThenListen(reply.text) }
      } else if voiceModeOn {
        listenInVoiceMode()
      }

      // Last, so a reload never holds up the reply that is already written or the voice reading it
      // out: by here the reply is done with, and the engine is put back together for the next one.
      await reloadIfNeeded()
    }
  }

  /// One turn of voice mode. The reply is spoken in full unless something interrupts it — sending,
  /// stopping, or tapping the microphone all do — and only a reply that finished on its own opens
  /// the microphone again, so an interruption is the end of the turn and not the start of another.
  /// Read first, listen after: the microphone stays shut while the voice is going, so the phone
  /// never takes down its own reply.
  private func speakThenListen(_ text: String) async {
    await speechOutput.speak(Self.spokenForm(of: text), voice: settings.voiceIdentifier)
    if voiceModeOn { listenInVoiceMode() }
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
    imageGenerator: (@Sendable (String) async throws -> Data)?,
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
    if image != nil, !supportsImages {
      chatNotice =
        "The model that's loaded can't see photos, so it answered the words alone. Switch to "
        + "Anvil Core in Settings › Models to send photos."
    }
    let stream = try await device.stream(
      prompt, imageData: supportsImages ? image?.jpegData : nil,
      maxReplyTokens: maxReplyTokens > 0 ? maxReplyTokens : nil,
      webSearch: webSearch, imageGenerator: imageGenerator)
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
    case .generatingImage(let prompt):
      updateMessage(replyID) { $0.imagePrompt = prompt }
    case .imageDeferred(let prompt):
      // Shown as being made from now — the brush under the words — and made once they stop.
      updateMessage(replyID) { $0.imagePrompt = prompt }
      deferredPicture = prompt
    case .imageGenerated(let data, let prompt):
      if let image = ImageProcessing.decode(data) { images[replyID] = image }
      updateMessage(replyID) {
        $0.hasImage = true
        $0.imagePrompt = prompt
      }
      if firstPiece == nil {
        firstPiece = started.duration(to: .now)
        replyStarted += 1
      }
      let chatID = openChat.id
      Task { try? await archive.saveImage(data, chatID: chatID, messageID: replyID) }
    case .imageGenerationFailed(let message):
      updateMessage(replyID) { $0.imagePrompt = nil }
      chatNotice = "Couldn't make the picture: \(message)"
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
    openChat = Chat(systemPrompt: settings.systemPrompt)
    images = [:]
    pendingImage = nil
    pendingFile = nil
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

  /// What the model is told and how it samples. The prompt a chat carries and custom sampling
  /// are Anvil Pro: without it the chat runs on the default prompt and the model's own sampling,
  /// whatever the settings file says — the file is where a Pro subscriber's choices wait, not
  /// where Pro is decided.
  private func conversationOptions() -> ConversationOptions {
    let values = settings.values
    let isPro = pro.isUnlocked
    let custom = openChat.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    // Voice mode runs on its own prompt — the same Anvil, answering in a sentence or three — in
    // place of the default. A prompt of the subscriber's own is kept, and told about the voice.
    let systemPrompt: String
    if voiceModeOn, !(isPro && !custom.isEmpty) {
      systemPrompt = AppSettings.voiceSystemPrompt
    } else {
      systemPrompt = isPro ? AppSettings.prompt(for: openChat.systemPrompt) : AppSettings.defaultSystemPrompt
    }
    return ConversationOptions(
      systemPrompt: systemPrompt,
      modelName: loadedModel?.spokenName ?? AppFlavor.productName,
      sampler: isPro && !values.useModelSamplerDefaults ? values.sampler : nil,
      webSearch: webSearchOn,
      memoryEnabled: values.memoryEnabled,
      memories: values.memoryEnabled ? memory.promptItems : [],
      imageGeneration: canGenerateImages,
      spokenReplies: voiceModeOn)
  }

  private func updateMessage(_ id: ChatMessage.ID, _ change: (inout ChatMessage) -> Void) {
    guard let index = openChat.messages.firstIndex(where: { $0.id == id }) else { return }
    change(&openChat.messages[index])
  }

  /// The most recent turns that fit in about half the context (roughly four characters per token),
  /// leaving room for the new message and its reply. Photos aren't re-sent, and neither are the
  /// pictures Anvil Dream made; both are noted in text.
  private static func historyTurns(_ messages: [ChatMessage], contextSize: Int) -> [HistoryTurn] {
    var remaining = contextSize * 2
    var turns: [HistoryTurn] = []
    for message in messages.reversed() where !message.isError {
      let note: String
      if !message.hasImage {
        note = ""
      } else if message.role == .user {
        note = "(shared a photo) "
      } else {
        note = "(made a picture of: \(message.imagePrompt ?? "what was asked for")) "
      }
      let text = (note + message.promptText).trimmingCharacters(in: .whitespaces)
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
