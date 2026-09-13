import SwiftUI

/// Setting the passcode: type it, type it again. Changing it: the current one first. One field
/// per step, the number pad up, and the sheet closes itself when the new passcode is saved.
struct PasscodeSheet: View {
  enum Mode: String, Identifiable {
    case set
    case change
    var id: String { rawValue }
  }

  let mode: Mode
  /// Called with the passcode once it is saved.
  var onSaved: () -> Void = {}

  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var step: Step
  @State private var code = ""
  @State private var firstEntry = ""
  @State private var problem: String?
  @State private var isChecking = false
  @FocusState private var isEntering: Bool

  private enum Step {
    case current
    case new
    case again
  }

  init(mode: Mode, onSaved: @escaping () -> Void = {}) {
    self.mode = mode
    self.onSaved = onSaved
    _step = State(initialValue: mode == .change ? .current : .new)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Spacer(minLength: 24)
        Text(prompt)
          .font(.title3.weight(.semibold))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
        Text("\(AppLock.minimumLength) to \(AppLock.maximumLength) digits.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        PasscodeField("Passcode", code: $code, isFocused: $isEntering, onSubmit: advance)
        if let problem {
          Text(problem)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
        Spacer()
        Button(action: advance) {
          Group {
            if isChecking {
              ProgressView().tint(theme.sendGlyph)
            } else {
              Text(step == .again ? "Save" : "Continue")
            }
          }
          .font(.headline)
          .frame(maxWidth: .infinity)
          .frame(height: ChatStyle.control)
          .background(theme.sendFill, in: Capsule())
          .foregroundStyle(theme.sendGlyph)
        }
        .buttonStyle(.plain)
        .disabled(isChecking || !AppLock.isValid(code))
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
      }
      .navigationTitle(mode == .set ? "Set a passcode" : "Change passcode")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .onAppear { isEntering = true }
    }
  }

  private var prompt: String {
    switch step {
    case .current: "Enter your current passcode"
    case .new: mode == .set ? "Choose a passcode" : "Choose a new passcode"
    case .again: "Enter it again"
    }
  }

  private func advance() {
    guard AppLock.isValid(code), !isChecking else { return }
    let entered = code
    switch step {
    case .current:
      isChecking = true
      Task {
        let ok = await AppLock.verify(entered)
        isChecking = false
        if ok {
          problem = nil
          step = .new
        } else {
          problem = "Wrong passcode"
        }
        code = ""
        isEntering = true
      }
    case .new:
      firstEntry = entered
      problem = nil
      step = .again
      code = ""
      isEntering = true
    case .again:
      guard entered == firstEntry else {
        problem = "They didn't match. Start again."
        firstEntry = ""
        step = .new
        code = ""
        isEntering = true
        return
      }
      do {
        try AppLock.setPasscode(entered)
        onSaved()
        dismiss()
      } catch {
        problem = error.localizedDescription
        code = ""
        isEntering = true
      }
    }
  }
}
