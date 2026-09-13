import SwiftUI

/// Voice mode, laid over the chat: a circle in the middle of the screen that swells with the
/// voice as it reads, the microphone under it showing what it hears and the words as they are
/// taken down, and the one way out. The chat stays visible through it and goes on updating, so
/// what is being said can be read as well as heard.
struct VoiceModeView: View {
  let chat: ChatModel

  @Environment(\.theme) private var theme

  private static let circle: CGFloat = 156

  var body: some View {
    ZStack {
      // Enough of the page to read the chat through, not enough for the chat to compete.
      theme.page.opacity(0.84)
        .ignoresSafeArea()
        .contentShape(Rectangle())

      VStack(spacing: 28) {
        Spacer()
        circle
        Text(status)
          .font(.headline)
          .foregroundStyle(.secondary)
          .contentTransition(.opacity)
          .animation(.easeInOut(duration: 0.2), value: status)
        Spacer()
        microphone
        closeButton
          .padding(.bottom, 12)
      }
      .padding(.horizontal, 24)
    }
    .accessibilityAddTraits(.isModal)
  }

  // MARK: - The voice

  /// The reply's presence. It grows with each word the voice starts and settles between them, on a
  /// spring quick enough to follow speech; thinking is a slow breath; listening is still.
  private var circle: some View {
    let level = CGFloat(chat.speechOutput.level)
    let breathing = chat.voicePhase == .thinking
    return Button(action: chat.tapVoiceCircle) {
      ZStack {
        Circle()
          .fill(theme.sendFill.opacity(0.18))
          .frame(width: Self.circle * 1.5, height: Self.circle * 1.5)
          .scaleEffect(1 + level * 0.25)
        Circle()
          .fill(theme.sendFill)
          .frame(width: Self.circle, height: Self.circle)
          .scaleEffect(1 + level * 0.35)
          .shadow(color: theme.sendFill.opacity(0.35 * level), radius: 24)
      }
      .animation(.spring(duration: 0.18, bounce: 0.25), value: level)
      .phaseAnimator([1.0, 1.05], trigger: breathing) { view, scale in
        view.scaleEffect(breathing ? scale : 1)
      } animation: { _ in
        breathing ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .easeInOut(duration: 0.3)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(status)
    .accessibilityHint(
      chat.voicePhase == .speaking ? "Stops the reply so you can talk" : "Starts listening")
  }

  private var status: String {
    switch chat.voicePhase {
    case .listening: "Listening"
    case .thinking: "Thinking"
    case .speaking: "Speaking"
    case .idle: "Tap to talk"
    }
  }

  // MARK: - The microphone

  /// What the microphone hears, as the wave the composer uses but larger, and the words it has
  /// made of it so far.
  private var microphone: some View {
    VStack(spacing: 14) {
      HStack(spacing: 14) {
        Image(systemName: "mic.fill")
          .font(.system(size: 20, weight: .medium))
          .foregroundStyle(chat.speechInput.isActive ? Color.primary : Color.secondary)
        SpeechWave(level: CGFloat(chat.speechInput.level), height: 36)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 14)
      .liquidGlass(in: Capsule())
      .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 0.5))

      let heard = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
      Text(heard.isEmpty ? " " : heard)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44, alignment: .top)
        .animation(.easeOut(duration: 0.15), value: heard)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      chat.draft.isEmpty ? "Microphone" : "Heard: \(chat.draft)")
  }

  private var closeButton: some View {
    Button(action: chat.endVoiceMode) {
      Image(systemName: "xmark")
        .font(.system(size: ChatStyle.controlGlyph, weight: .medium))
        .frame(width: ChatStyle.control, height: ChatStyle.control)
        .liquidGlass(in: Circle(), interactive: true)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .accessibilityLabel("End voice mode")
  }
}
