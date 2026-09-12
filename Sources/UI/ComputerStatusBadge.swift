import SwiftUI

/// A dot in the chat toolbar showing whether your computer can be reached. It appears only when
/// replies are allowed to run there. Tap it to check again.
struct ComputerStatusBadge: View {
  let chat: ChatModel

  var body: some View {
    if chat.settings.values.replyLocation != .iPhone {
      Button {
        Task { await chat.refreshComputerStatus() }
      } label: {
        HStack(spacing: 4) {
          Circle()
            .fill(color)
            .frame(width: 7, height: 7)
          Image(systemName: "desktopcomputer")
            .font(.caption)
        }
      }
      .accessibilityLabel("My computer: \(chat.computerState.label)")
      .accessibilityHint("Checks the connection again")
    }
  }

  private var color: Color {
    switch chat.computerState {
    case .online: .green
    case .checking, .notUsed: .gray
    case .notConfigured, .unreachable: .red
    }
  }
}
