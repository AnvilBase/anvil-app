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

  /// How loud the microphone is right now, nought to one. Only the wave in the composer reads it;
  /// nothing dictation does depends on it.
  private(set) var level: Float = 0

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

  /// Voice mode keeps the microphone open while a reply is being read, so the voice and the
  /// microphone share one session — set for a conversation, with the phone cancelling its own
  /// voice out of what the microphone hears — and stopping leaves that session as it is.
  private var sharedSession = false

  /// Starts listening. `onUpdate` receives the live transcript; `onFinish` receives the final text
  /// when listening stops, whether you tap stop or simply pause. With `sharedSession`, the audio
  /// session is set up for talking and listening at once, and left standing when listening ends.
  func start(
    stopAfterSilence: Bool, sharedSession: Bool = false, onUpdate: @escaping (String) -> Void,
    onFinish: @escaping (String) -> Void
  ) async throws {
    guard state == .idle else { return }
    try await Self.requestPermissions()
    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
      throw SpeechInputError.unavailable
    }
    guard recognizer.supportsOnDeviceRecognition else { throw SpeechInputError.onDeviceUnavailable }

    let session = AVAudioSession.sharedInstance()
    self.sharedSession = sharedSession
    if sharedSession {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
    } else {
      try session.setCategory(
        .playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
    }
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.addsPunctuation = true

    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else { throw SpeechInputError.unavailable }
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      request.append(buffer)
      let loudness = Self.loudness(of: buffer)
      Task { @MainActor in self?.absorb(loudness) }
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

  /// Starts ending on a pause, for a listener that was opened without one: voice mode opens the
  /// microphone before it knows whether anyone will speak, and only once words arrive should a
  /// pause mean the turn is over.
  func armSilenceStop() {
    guard state == .listening, !stopAfterSilence else { return }
    stopAfterSilence = true
    scheduleStop(after: Self.pauseLength)
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
    level = 0
  }

  /// How loud one buffer is, on a scale a bar can be drawn from: a quiet room near nought, talking
  /// into the phone near one.
  ///
  /// Runs on the audio thread, so it touches nothing but the buffer it was handed.
  private nonisolated static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
    guard let channel = buffer.floatChannelData?[0] else { return 0 }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return 0 }
    var sum: Float = 0
    for frame in 0..<count { sum += channel[frame] * channel[frame] }
    let rms = (sum / Float(count)).squareRoot()
    // Loudness is logarithmic; a bar drawn straight from the raw value barely leaves the floor.
    // -50dB is a quiet room and -10dB is someone talking into the phone, so that is the range the
    // bars get to use.
    let decibels = 20 * log10(max(rms, 1e-7))
    return min(max((decibels + 50) / 40, 0), 1)
  }

  /// Quick to rise so a word registers the moment it is said, slower to fall so the bars settle
  /// between syllables instead of flickering.
  private func absorb(_ loudness: Float) {
    guard state == .listening else { return }
    let next = loudness > level ? loudness : level * 0.8 + loudness * 0.2
    // Buffers arrive around fifty times a second and each one that moves this redraws the row.
    // A change too small to see isn't worth a frame.
    guard abs(next - level) > 0.02 || (next == 0 && level != 0) else { return }
    level = next
  }

  private func complete() {
    guard state != .idle else { return }
    state = .idle
    timer?.cancel()
    timer = nil
    task?.cancel()
    task = nil
    request = nil
    if !sharedSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
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
