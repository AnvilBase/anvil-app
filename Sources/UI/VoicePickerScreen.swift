import AVFoundation
import SwiftUI

/// Which voice reads replies. The installed voices for the phone's language, best first, each
/// heard with a tap; and, because the good ones aren't on the phone until someone fetches them,
/// where they come from.
struct VoicePickerScreen: View {
  @Bindable var settings: SettingsStore
  let speech: SpeechOutput

  @Environment(\.theme) private var theme
  @State private var voices = SpeechVoices.installed()

  private var chosen: String { settings.values.voiceIdentifier }

  var body: some View {
    List {
      Section {
        row(
          title: "Automatic", detail: automaticDetail, selected: chosen == SpeechVoices.automatic
        ) {
          choose(SpeechVoices.automatic)
        }
      } footer: {
        Text("The best-sounding voice installed for \(languageName).")
      }

      Section {
        ForEach(voices, id: \.identifier) { voice in
          row(
            title: voice.name, detail: "\(SpeechVoices.grade(of: voice)) · \(region(of: voice))",
            selected: chosen == voice.identifier
          ) {
            choose(voice.identifier)
          }
        }
      } header: {
        Text(languageName)
      } footer: {
        Text(downloadHint)
      }
    }
    .navigationTitle("Voice")
    // Voices downloaded in the Settings app show up here on the way back.
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) {
      _ in voices = SpeechVoices.installed()
    }
    .onDisappear(perform: speech.stop)
  }

  /// Chosen, and heard: the sample line in that voice, so the choice can be made by ear.
  private func choose(_ identifier: String) {
    settings.values.voiceIdentifier = identifier
    Task { await speech.speak(SpeechVoices.sample, voice: identifier) }
  }

  private func row(
    title: String, detail: String, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if selected {
          Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(theme.sendFill)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var automaticDetail: String {
    guard let best = SpeechVoices.voice(for: SpeechVoices.automatic) else { return "No voice installed" }
    return "\(best.name), \(SpeechVoices.grade(of: best).lowercased())"
  }

  /// "English", from the phone's language.
  private var languageName: String {
    let tag = SpeechVoices.preferredLanguage
    let code = String(tag.prefix(while: { $0 != "-" }))
    return Locale.current.localizedString(forLanguageCode: code) ?? tag
  }

  /// "United States", from the voice's language tag.
  private func region(of voice: AVSpeechSynthesisVoice) -> String {
    let region = Locale(identifier: voice.language).region?.identifier ?? ""
    return Locale.current.localizedString(forRegionCode: region) ?? voice.language
  }

  /// The compact voices are what ship; the ones worth having are a download away, in a place
  /// nobody would find on their own.
  private var downloadHint: String {
    let lead = SpeechVoices.hasNaturalVoice
      ? "More voices are free to add."
      : "Only the standard voice is installed, which is the one that sounds robotic. Premium voices "
        + "sound close to Siri, and they're free."
    return lead
      + " In the Settings app, go to Accessibility › Spoken Content › Voices, pick \(languageName) "
      + "and a voice, and download its Premium version. It appears here once it's on the phone."
  }
}
