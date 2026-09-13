import SwiftUI

/// What is on screen while the app is locked: the mark, one line, and the passcode field, with
/// the keyboard already up. Enough digits and Unlock tries them. While the app is merely covered —
/// inactive, not gone — it is the mark alone: nothing to ask, nothing to type.
struct LockScreen: View {
  let lock: AppLock

  @Environment(\.theme) private var theme
  @State private var code = ""
  @FocusState private var isEntering: Bool

  var body: some View {
    VStack(spacing: 28) {
      Spacer()
      PixelAnvil(size: 56)
      if lock.isLocked {
        Text("Anvil is locked")
          .font(.title3.weight(.semibold))
        PasscodeField(
          "Passcode", code: $code, isFocused: $isEntering, onSubmit: { Task { await tryUnlock() } })
        if let problem = lock.problem {
          Text(problem)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
      }
      Spacer()
      if lock.isLocked {
        Button {
          Task { await tryUnlock() }
        } label: {
          Group {
            if lock.isChecking {
              ProgressView().tint(theme.sendGlyph)
            } else {
              Text("Unlock")
            }
          }
          .font(.headline)
          .frame(maxWidth: .infinity)
          .frame(height: ChatStyle.control)
          .background(theme.sendFill, in: Capsule())
          .foregroundStyle(theme.sendGlyph)
        }
        .buttonStyle(.plain)
        .disabled(lock.isChecking || code.count < AppLock.minimumLength)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.page.ignoresSafeArea())
    .onAppear { if lock.isLocked { isEntering = true } }
    .onChange(of: lock.isLocked) { _, locked in
      code = ""
      isEntering = locked
    }
  }

  private func tryUnlock() async {
    guard code.count >= AppLock.minimumLength else { return }
    let entered = code
    if !(await lock.unlock(with: entered)) {
      code = ""
      isEntering = true
    }
  }
}

/// A field for digits and nothing else, hidden as they are typed, the number pad under it.
/// Shared by the lock screen and the passcode sheet so a passcode looks the same being set as
/// being asked for.
struct PasscodeField: View {
  let title: String
  @Binding var code: String
  var isFocused: FocusState<Bool>.Binding
  var onSubmit: () -> Void = {}

  init(
    _ title: String, code: Binding<String>, isFocused: FocusState<Bool>.Binding,
    onSubmit: @escaping () -> Void = {}
  ) {
    self.title = title
    _code = code
    self.isFocused = isFocused
    self.onSubmit = onSubmit
  }

  var body: some View {
    SecureField(title, text: $code)
      .keyboardType(.numberPad)
      .textContentType(.oneTimeCode)
      .multilineTextAlignment(.center)
      .font(.title2.monospacedDigit())
      .padding(.vertical, 12)
      .padding(.horizontal, 16)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal, 48)
      .focused(isFocused)
      .onSubmit(onSubmit)
      .onChange(of: code) { _, value in
        // Digits only, and no more of them than a passcode can be.
        let digits = String(value.filter(\.isNumber).prefix(AppLock.maximumLength))
        if digits != value { code = digits }
      }
  }
}
