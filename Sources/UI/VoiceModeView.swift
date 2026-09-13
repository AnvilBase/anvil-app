import SwiftUI

/// Voice mode, as a small card that comes out from under its button: a circle that swells with the
/// voice as it reads, and the microphone under it, moving with what it hears. Nothing else. The
/// words you say land in the composer and the reply lands in the chat, as they always do; this is
/// only the part you talk to.
struct VoiceModeView: View {
  let chat: ChatModel

  @Environment(\.theme) private var theme

  /// Where the card has been dragged to, from where it opened. Kept while the card is up.
  @State private var placed = CGSize.zero
  @GestureState private var dragging = CGSize.zero

  private static let circle: CGFloat = 64

  var body: some View {
    VStack(spacing: 14) {
      circle
      microphone
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .liquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .strokeBorder(theme.hairline, lineWidth: 0.5))
    .offset(x: placed.width + dragging.width, y: placed.height + dragging.height)
    // The card goes where it is put. A drag from anywhere on it, the circle included, moves it;
    // a tap is still a tap, since a drag has to travel a little before it counts as one.
    .highPriorityGesture(
      DragGesture(minimumDistance: 6)
        .updating($dragging) { value, state, _ in state = value.translation }
        .onEnded { value in
          placed.width += value.translation.width
          placed.height += value.translation.height
        }
    )
    .animation(.interactiveSpring(duration: 0.2), value: dragging)
    .accessibilityElement(children: .contain)
  }

  /// The reply's presence. It grows with each word the voice starts and settles between them, on a
  /// spring quick enough to follow speech; thinking is a slow breath; listening is still. Tapped,
  /// it cuts a reply off and listens, or ends a turn and sends it.
  private var circle: some View {
    let level = CGFloat(chat.speechOutput.level)
    let breathing = chat.voicePhase == .thinking
    return Button(action: chat.tapVoiceCircle) {
      ZStack {
        Circle()
          .fill(theme.sendFill.opacity(0.18))
          .frame(width: Self.circle * 1.45, height: Self.circle * 1.45)
          .scaleEffect(1 + level * 0.25)
        Circle()
          .fill(theme.sendFill)
          .frame(width: Self.circle, height: Self.circle)
          .scaleEffect(1 + level * 0.3)
      }
      .frame(width: Self.circle * 1.45 * 1.3, height: Self.circle * 1.45 * 1.3)
      .animation(.spring(duration: 0.18, bounce: 0.25), value: level)
      .phaseAnimator([1.0, 1.06], trigger: breathing) { view, scale in
        view.scaleEffect(breathing ? scale : 1)
      } animation: { _ in
        breathing
          ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
          : .easeInOut(duration: 0.3)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(status)
    .accessibilityHint(
      chat.voicePhase == .speaking ? "Stops the reply so you can talk" : "Listens, or sends")
  }

  private var status: String {
    switch chat.voicePhase {
    case .listening: "Listening"
    case .thinking: "Thinking"
    case .speaking: "Speaking"
    case .idle: "Voice mode"
    }
  }

  /// What the microphone hears, as the wave the composer uses. Dim while the microphone is shut —
  /// while a reply is being read, or made.
  private var microphone: some View {
    HStack(spacing: 10) {
      Image(systemName: "mic.fill")
        .font(.system(size: 15, weight: .medium))
      SpeechWave(level: CGFloat(chat.speechInput.level), height: 22)
    }
    .foregroundStyle(chat.speechInput.isActive ? Color.primary : Color.secondary)
    .animation(.easeInOut(duration: 0.2), value: chat.speechInput.isActive)
    .accessibilityLabel(chat.speechInput.isActive ? "Microphone on" : "Microphone off")
  }
}
