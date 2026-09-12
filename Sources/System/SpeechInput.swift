import AVFoundation
import Observation
import Speech

enum SpeechInputError: LocalizedError {
  case speechDenied
  case microphoneDenied
  case unavailable
  case onDeviceUnavailable

  var errorDescription: String? {
    switch self {
    case .speechDenied:
      "Speech recognition is off for \(AppFlavor.appName). Turn it on in Settings › Privacy & "
        + "Security › Speech Recognition."
    case .microphoneDenied:
      "Microphone access is off for \(AppFlavor.appName). Turn it on in Settings › Privacy & "
        + "Security › Microphone."
    case .unavailable:
      "Speech recognition isn't available right now."
    case .onDeviceUnavailable:
      "On-device speech recognition isn't available for your language, and \(AppFlavor.appName) "
        + "won't send audio to Apple's servers. Check that your dictation language is downloaded in "
        + "Settings › General › Keyboard."
    }
  }
}

/// Dictation with Apple's speech recognizer, restricted to on-device recognition so audio never
/// leaves the phone.
///
/// If the language can't be recognized on-device, dictation is refused rather than quietly sent to
/// Apple's servers. Speech goes into the message field; replies are never read aloud.
@MainActor
@Observable
final class SpeechInput {
  enum State: Equatable {
    case idle
    case listening
    /// The microphone is off; waiting a moment for the recognizer's final result.
    case finishing
  }

  private(set) var state: State = .idle

  var isActive: Bool { state != .idle }

  /// A pause this long ends dictation when "send when you stop talking" is on.
  private static let pauseLength: Duration = .seconds(1.8)
  /// How long to wait for the first words before giving up.
  private static let startTimeout: Duration = .seconds(8)

  private let audioEngine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var timer: Task<Void, Never>?
  private var transcript = ""
  private var stopAfterSilence = false
  private var onUpdate: ((String) -> Void)?
  private var onFinish: ((String) -> Void)?

  /// Starts listening. `onUpdate` receives the live transcript; `onFinish` receives the final text
  /// when listening stops, whether you tap stop or simply pause.
  func start(
    stopAfterSilence: Bool, onUpdate: @escaping (String) -> Void,
    onFinish: @escaping (String) -> Void
  ) async throws {
    guard state == .idle else { return }
    try await Self.requestPermissions()
    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
      throw SpeechInputError.unavailable
    }
    guard recognizer.supportsOnDeviceRecognition else { throw SpeechInputError.onDeviceUnavailable }

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.addsPunctuation = true

    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else { throw SpeechInputError.unavailable }
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      request.append(buffer)
    }
    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }

    self.request = request
    self.stopAfterSilence = stopAfterSilence
    self.onUpdate = onUpdate
    self.onFinish = onFinish
    transcript = ""
    state = .listening
    if stopAfterSilence { scheduleStop(after: Self.startTimeout) }

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let failed = error != nil
      Task { @MainActor in
        self?.handle(text: text, isFinal: isFinal, failed: failed)
      }
    }
  }

  /// Stops listening and hands the transcript to `onFinish`.
  func stop() {
    guard state == .listening else { return }
    state = .finishing
    stopAudio()
    request?.endAudio()
    // The final result usually arrives within a moment; don't wait longer than that.
    scheduleCompletion(after: .seconds(1))
  }

  /// Stops listening and throws the transcript away.
  func cancel() {
    guard state != .idle else { return }
    onFinish = nil
    if state == .listening { stopAudio() }
    complete()
  }

  private func handle(text: String?, isFinal: Bool, failed: Bool) {
    guard state != .idle else { return }
    if let text, !text.isEmpty {
      transcript = text
      onUpdate?(text)
      if state == .listening, stopAfterSilence { scheduleStop(after: Self.pauseLength) }
    }
    if isFinal || failed {
      if state == .listening { stopAudio() }
      complete()
    }
  }

  private func scheduleStop(after delay: Duration) {
    timer?.cancel()
    timer = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.stop()
    }
  }

  private func scheduleCompletion(after delay: Duration) {
    timer?.cancel()
    timer = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.complete()
    }
  }

  private func stopAudio() {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
  }

  private func complete() {
    guard state != .idle else { return }
    state = .idle
    timer?.cancel()
    timer = nil
    task?.cancel()
    task = nil
    request = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    let finish = onFinish
    let text = transcript
    onUpdate = nil
    onFinish = nil
    finish?(text)
  }

  private static func requestPermissions() async throws {
    let status = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard status == .authorized else { throw SpeechInputError.speechDenied }
    guard await AVAudioApplication.requestRecordPermission() else {
      throw SpeechInputError.microphoneDenied
    }
  }
}
