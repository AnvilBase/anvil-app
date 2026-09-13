import AVFoundation

/// The voices this iPhone can read a reply with, and which of them to use.
///
/// iOS ships each voice in up to three grades. The compact one is installed by default and is the
/// flat, clipped voice people mean when they say the phone sounds robotic; the enhanced and
/// premium grades are neural, sound close to Siri, and are free — but they have to be downloaded
/// once, in the Settings app, and an app can't do that for you. So the app's job is to use the
/// best voice that is there, say which it is, and say where better ones come from.
enum SpeechVoices {
  /// The setting's value for "whichever installed voice sounds best".
  static let automatic = ""

  /// A line to hear a voice by, before choosing it.
  static let sample = "Hi, I'm Anvil. This is how I sound."

  /// What the phone speaks: the user's first preferred language as the BCP-47 tag the synthesiser
  /// wants ("en-US", not the locale's "en_US").
  static var preferredLanguage: String { Locale.preferredLanguages.first ?? "en-US" }

  /// The installed voices for a language, best-sounding first: premium, then enhanced, then the
  /// compact ones; within a grade the one iOS itself reads with, then the phone's own region, then
  /// by name. All regions of the language are listed, so a British voice can be chosen on an
  /// American phone. Novelty voices are left out.
  static func installed(for language: String = preferredLanguage) -> [AVSpeechSynthesisVoice] {
    let base = language.prefix(while: { $0 != "-" }).lowercased()
    let system = AVSpeechSynthesisVoice(language: language)?.identifier
    return AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.lowercased().hasPrefix(base) && !isNovelty($0) }
      .sorted { a, b in
        if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
        let aSystem = a.identifier == system, bSystem = b.identifier == system
        if aSystem != bSystem { return aSystem }
        let aHere = a.language == language, bHere = b.language == language
        if aHere != bHere { return aHere }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
      }
  }

  /// The voice to read with: the chosen one, if it is still installed, and otherwise the best that
  /// is. English if the phone's language has no voice at all.
  static func voice(for identifier: String) -> AVSpeechSynthesisVoice? {
    if !identifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
      return chosen
    }
    return installed().first
      ?? AVSpeechSynthesisVoice(language: preferredLanguage)
      ?? AVSpeechSynthesisVoice(language: "en-US")
  }

  /// The grade, as the Settings app names it.
  static func grade(of voice: AVSpeechSynthesisVoice) -> String {
    switch voice.quality {
    case .premium: "Premium"
    case .enhanced: "Enhanced"
    default: "Standard"
    }
  }

  /// Whether any voice installed for the phone's language is better than compact.
  static var hasNaturalVoice: Bool {
    installed().contains { $0.quality != .default }
  }

  /// Bells, Bubbles and the rest: fun once, and not what anyone wants a reply read in.
  private static func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
    if #available(iOS 17.0, *) {
      return voice.voiceTraits.contains(.isNoveltyVoice)
    }
    return false
  }
}
