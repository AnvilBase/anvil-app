import SwiftUI

/// What is on screen while the app is locked: the mark, one line, and the way in. It asks Face ID
/// itself the moment it appears, so the button is only for the second try.
struct LockScreen: View {
  let lock: AppLock

  @Environment(\.theme) private var theme

  var body: some View {
    VStack(spacing: 28) {
      Spacer()
      PixelAnvil(size: 56)
      Text("Anvil is locked")
        .font(.title3.weight(.semibold))
      if let problem = lock.problem {
        Text(problem)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
      }
      Spacer()
      Button {
        Task { await lock.unlock() }
      } label: {
        Text("Unlock")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .frame(height: ChatStyle.control)
          .background(theme.sendFill, in: Capsule())
          .foregroundStyle(theme.sendGlyph)
      }
      .buttonStyle(.plain)
      .disabled(lock.isAuthenticating)
      .padding(.horizontal, 24)
      .padding(.bottom, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.page.ignoresSafeArea())
    .task { await lock.unlock() }
  }
}
