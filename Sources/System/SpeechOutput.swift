import AVFoundation
import Foundation
import Observation

/// Reads a reply aloud, on this iPhone, with the voices iOS ships.
///
/// `AVSpeechSynthesizer` runs on the device — nothing is sent anywhere to be spoken — which is the
/// only kind of voice this app could have. It speaks one reply at a time and stops the moment it
/// is asked to, so the person talking is never talked over.
@MainActor
@Observable
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
  private(set) var isSpeaking = false

  /// How much the voice is saying right now, nought to one, for something on screen to move with.
  /// The synthesiser reports no loudness, so this is built from the words: each one it starts
  /// lifts the level, longer words more, and it falls away between them.
  private(set) var level: Float = 0

  /// Voice mode holds the audio session open for the microphone and the voice together, so
  /// speaking mustn't take it back for playback alone; with this set, the session is left as it is.
  var sharesAudioSession = false

  private let synthesizer = AVSpeechSynthesizer()
  private var finished: CheckedContinuation<Void, Never>?
  private var decay: Task<Void, Never>?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  /// Speaks the text and returns when it has finished — or straight away if it was stopped.
  func speak(_ text: String) async {
    stop()
    let utterance = AVSpeechUtterance(string: text)
    // The user's first preferred language, as the BCP-47 tag the synthesiser wants ("en-US",
    // not the locale's "en_US"), and English only if there is no voice for it.
    utterance.voice =
      Locale.preferredLanguages.first.flatMap { AVSpeechSynthesisVoice(language: $0) }
      ?? AVSpeechSynthesisVoice(language: "en-US")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    if !sharesAudioSession {
      // Playback rather than record, and mixed rather than exclusive, so speaking a reply doesn't
      // silence whatever else is playing and doesn't fight the microphone for the session.
      try? AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .spokenAudio, options: [.duckOthers])
      try? AVAudioSession.sharedInstance().setActive(true)
    }
    isSpeaking = true
    startDecay()
    await withCheckedContinuation { continuation in
      finished = continuation
      synthesizer.speak(utterance)
    }
  }

  func stop() {
    guard isSpeaking else { return }
    synthesizer.stopSpeaking(at: .immediate)
    settle()
  }

  private func settle() {
    isSpeaking = false
    decay?.cancel()
    decay = nil
    level = 0
    finished?.resume()
    finished = nil
  }

  /// Lets the level fall between words: a quick ease down to a murmur while the voice is going,
  /// so the shape it drives breathes with the speech rather than jumping word to word.
  private func startDecay() {
    decay?.cancel()
    decay = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(40))
        guard let self, isSpeaking else { return }
        let floor: Float = 0.12
        level = max(level * 0.86, floor)
      }
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    let lift = 0.55 + min(Float(characterRange.length), 12) / 12 * 0.45
    Task { @MainActor in
      guard self.isSpeaking else { return }
      self.level = max(self.level, lift)
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.settle() }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.settle() }
  }
}
