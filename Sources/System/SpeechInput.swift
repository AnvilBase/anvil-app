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

/// Dictation, on this iPhone, so audio never leaves the phone.
///
/// On iOS 26 the words come from Apple's `SpeechAnalyzer`, the recogniser behind the system's own
/// dictation: faster than the old one, far fewer wrong words, and no limit on how long it will
/// listen. Older phones get `SFSpeechRecognizer`, restricted to on-device recognition. Either way,
/// if the language can't be recognised on the phone, dictation is refused rather than quietly sent
/// to Apple's servers. Speech goes into the message field; replies are never read here.
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
  private var backend: (any TranscriptionBackend)?
  private var timer: Task<Void, Never>?
  private var transcript = ""
  private var stopAfterSilence = false
  private var onUpdate: ((String) -> Void)?
  private var onFinish: ((String) -> Void)?

  /// Voice mode takes turns between the voice and the microphone many times a minute, so the two
  /// share one audio session, set for a conversation, and stopping leaves that session as it is
  /// rather than tearing it down and building it back for the next turn.
  private var sharedSession = false

  /// Starts listening. `onUpdate` receives the live transcript; `onFinish` receives the final text
  /// when listening stops, whether you tap stop or simply pause. With `sharedSession`, the audio
  /// session is set up for talking and listening at once, and left standing when listening ends.
  func start(
    stopAfterSilence: Bool, sharedSession: Bool = false, onUpdate: @escaping (String) -> Void,
    onFinish: @escaping (String) -> Void
  ) async throws {
    guard state == .idle else { return }
    let backend = try await Self.makeBackend()

    let session = AVAudioSession.sharedInstance()
    self.sharedSession = sharedSession
    if sharedSession {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
    } else {
      try session.setCategory(
        .playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
    }
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else { throw SpeechInputError.unavailable }
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      backend.append(buffer)
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

    self.backend = backend
    self.stopAfterSilence = stopAfterSilence
    self.onUpdate = onUpdate
    self.onFinish = onFinish
    transcript = ""
    state = .listening
    if stopAfterSilence { scheduleStop(after: Self.startTimeout) }

    do {
      try await backend.begin { [weak self] text, finished, failed in
        Task { @MainActor in self?.handle(text: text, finished: finished, failed: failed) }
      }
    } catch {
      stopAudio()
      complete()
      throw error
    }
  }

  /// Stops listening and hands the transcript to `onFinish`.
  func stop() {
    guard state == .listening else { return }
    state = .finishing
    stopAudio()
    backend?.endAudio()
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

  private func handle(text: String?, finished: Bool, failed: Bool) {
    guard state != .idle else { return }
    if let text, !text.isEmpty, text != transcript {
      transcript = text
      onUpdate?(text)
      if state == .listening, stopAfterSilence { scheduleStop(after: Self.pauseLength) }
    }
    if finished || failed {
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
    backend?.cancel()
    backend = nil
    if !sharedSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    let finish = onFinish
    let text = transcript
    onUpdate = nil
    onFinish = nil
    finish?(text)
  }

  /// The recogniser for this phone: Apple's analyzer on iOS 26, the older one before it. Both
  /// need the microphone; only the older one needs speech-recognition permission of its own.
  private static func makeBackend() async throws -> any TranscriptionBackend {
    guard await AVAudioApplication.requestRecordPermission() else {
      throw SpeechInputError.microphoneDenied
    }
    if #available(iOS 26.0, *) {
      return try await AnalyzerTranscription.make()
    }
    let status = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard status == .authorized else { throw SpeechInputError.speechDenied }
    return try LegacyTranscription()
  }
}

// MARK: - The recognisers

/// What turns microphone buffers into words. `begin` starts reporting: the transcript so far, then
/// `finished` once, when there will be no more, or `failed`. Buffers can arrive from the audio
/// thread; everything else is called on the main actor.
private protocol TranscriptionBackend: AnyObject, Sendable {
  typealias Report = @Sendable (_ text: String?, _ finished: Bool, _ failed: Bool) -> Void
  func begin(_ report: @escaping Report) async throws
  func append(_ buffer: AVAudioPCMBuffer)
  /// No more audio is coming; finish what there is.
  func endAudio()
  func cancel()
}

/// Apple's `SpeechAnalyzer`, from iOS 26: the phone's own dictation, on the phone.
///
/// Results arrive as pieces of the transcript. A piece is volatile until the analyzer is sure of
/// it, and a later piece for the same stretch of audio replaces it; once final, it stays. The
/// transcript shown is everything final so far and the latest volatile piece after it.
@available(iOS 26.0, *)
private final class AnalyzerTranscription: TranscriptionBackend, @unchecked Sendable {
  private let transcriber: SpeechTranscriber
  private let analyzer: SpeechAnalyzer
  private let format: AVAudioFormat
  private let input: AsyncStream<AnalyzerInput>
  private let feed: AsyncStream<AnalyzerInput>.Continuation
  private var converter: AVAudioConverter?
  private let lock = NSLock()
  private var results: Task<Void, Never>?
  private var finalized = ""
  private var volatile = ""

  static func make() async throws -> AnalyzerTranscription {
    var chosen = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
    if chosen == nil { chosen = await SpeechTranscriber.supportedLocales.first }
    guard let locale = chosen else { throw SpeechInputError.onDeviceUnavailable }
    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [])
    // The language's model lives on the phone. The first time, iOS fetches it; after that this
    // returns nothing and there is nothing to wait for.
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    else { throw SpeechInputError.unavailable }
    return AnalyzerTranscription(transcriber: transcriber, format: format)
  }

  private init(transcriber: SpeechTranscriber, format: AVAudioFormat) {
    self.transcriber = transcriber
    self.format = format
    analyzer = SpeechAnalyzer(modules: [transcriber])
    (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
  }

  func begin(_ report: @escaping Report) async throws {
    results = Task { [transcriber] in
      do {
        for try await result in transcriber.results {
          let text = String(result.text.characters)
          let whole: String
          lock.lock()
          if result.isFinal {
            finalized += text
            volatile = ""
          } else {
            volatile = text
          }
          whole = finalized + volatile
          lock.unlock()
          report(whole, false, false)
        }
        lock.lock()
        let whole = finalized + volatile
        lock.unlock()
        report(whole, true, false)
      } catch {
        report(nil, true, true)
      }
    }
    try await analyzer.start(inputSequence: input)
  }

  /// From the microphone's format to the analyzer's, on the audio thread.
  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    if converter == nil { converter = AVAudioConverter(from: buffer.format, to: format) }
    let converter = converter
    lock.unlock()
    guard let converter else { return }
    if buffer.format == format {
      feed.yield(AnalyzerInput(buffer: buffer))
      return
    }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
    guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
    var handed = false
    var error: NSError?
    let status = converter.convert(to: converted, error: &error) { _, outStatus in
      if handed {
        outStatus.pointee = .noDataNow
        return nil
      }
      handed = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, converted.frameLength > 0 else { return }
    feed.yield(AnalyzerInput(buffer: converted))
  }

  func endAudio() {
    feed.finish()
    Task { [analyzer] in try? await analyzer.finalizeAndFinishThroughEndOfInput() }
  }

  func cancel() {
    feed.finish()
    results?.cancel()
    Task { [analyzer] in await analyzer.cancelAndFinishNow() }
  }
}

/// `SFSpeechRecognizer`, for phones before iOS 26, held to on-device recognition.
private final class LegacyTranscription: TranscriptionBackend, @unchecked Sendable {
  private let recognizer: SFSpeechRecognizer
  private let request: SFSpeechAudioBufferRecognitionRequest
  private var task: SFSpeechRecognitionTask?

  init() throws {
    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
      throw SpeechInputError.unavailable
    }
    guard recognizer.supportsOnDeviceRecognition else { throw SpeechInputError.onDeviceUnavailable }
    self.recognizer = recognizer
    request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.addsPunctuation = true
  }

  func begin(_ report: @escaping Report) async throws {
    task = recognizer.recognitionTask(with: request) { result, error in
      report(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
    }
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    request.append(buffer)
  }

  func endAudio() {
    request.endAudio()
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}
