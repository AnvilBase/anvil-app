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

  private let synthesizer = AVSpeechSynthesizer()
  private var finished: CheckedContinuation<Void, Never>?

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
    // Playback rather than record, and mixed rather than exclusive, so speaking a reply doesn't
    // silence whatever else is playing and doesn't fight the microphone for the session.
    try? AVAudioSession.sharedInstance().setCategory(
      .playback, mode: .spokenAudio, options: [.duckOthers])
    try? AVAudioSession.sharedInstance().setActive(true)
    isSpeaking = true
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
    finished?.resume()
    finished = nil
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
