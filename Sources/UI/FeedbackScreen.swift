import MessageUI
import SwiftUI

/// Writing to us from inside the app: feedback, or a bug report.
///
/// Pushed from Settings › Feedback. Each is a form and one button. Send puts what was written into
/// a mail addressed to `AppLinks.supportEmail` and raises it over the form, so the last look before
/// anything goes is at the mail itself; the app sends nothing of its own. Without Mail set up, the
/// message goes to whichever mail app takes a `mailto:` link, and without one of those it can be
/// copied, with the address, for anywhere else.
///
/// A bug report asks the three questions that make one answerable. Both end with one line of device
/// details — the build, the phone, iOS, the model in use, whether Pro is on — shown in full under
/// its switch, so what is included is never a surprise and can be left off.
struct FeedbackScreen: View {
  enum Kind {
    case feedback
    case bug
  }

  let kind: Kind
  let library: ModelLibrary

  @Environment(ProAccess.self) private var pro
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  /// The feedback itself, or what happened: the one field Send needs.
  @State private var message = ""
  @State private var expected = ""
  @State private var steps = ""
  @State private var includesDetails = true
  @State private var composing = false
  /// Set when the mail sheet reports the mail went, so the screen goes back to Settings once the
  /// sheet is down rather than while it is still closing.
  @State private var sent = false
  @State private var showingNoMailApp = false
  @FocusState private var focusedField: Field?

  private enum Field {
    case message
    case expected
    case steps
  }

  var body: some View {
    Form {
      switch kind {
      case .feedback: feedbackFields
      case .bug: bugFields
      }

      Section {
        Toggle("Include device details", isOn: $includesDetails)
      } footer: {
        Text(includesDetails ? deviceDetails : "Nothing about this phone is included.")
      }
    }
    .navigationTitle(kind == .feedback ? "Send feedback" : "Report a bug")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) { footer }
    .sheet(isPresented: $composing, onDismiss: { if sent { dismiss() } }) {
      MailComposer(subject: subject, body: mailBody) { result in
        sent = result == .sent
        composing = false
      }
      .ignoresSafeArea()
    }
    .alert("No mail app", isPresented: $showingNoMailApp) {
      Button("Copy message") { UIPasteboard.general.string = mailBody }
      Button("Copy address") { UIPasteboard.general.string = AppLinks.supportEmail }
      Button("OK", role: .cancel) {}
    } message: {
      Text("Copy the message and send it to \(AppLinks.supportEmail) from wherever you do your mail.")
    }
    .onAppear { focusedField = .message }
  }

  // MARK: - The form

  private var feedbackFields: some View {
    Section("Your feedback") {
      TextField("What's working, what isn't, what you'd like to see", text: $message, axis: .vertical)
        .lineLimit(6...14)
        .focused($focusedField, equals: .message)
    }
  }

  @ViewBuilder
  private var bugFields: some View {
    Section("What happened") {
      TextField("What went wrong", text: $message, axis: .vertical)
        .lineLimit(3...10)
        .focused($focusedField, equals: .message)
    }
    Section("What you expected") {
      TextField("Optional", text: $expected, axis: .vertical)
        .lineLimit(2...8)
        .focused($focusedField, equals: .expected)
    }
    Section {
      TextField("Optional", text: $steps, axis: .vertical)
        .lineLimit(3...10)
        .focused($focusedField, equals: .steps)
    } header: {
      Text("How to make it happen again")
    } footer: {
      Text("Step by step, if you know. A bug that can be made to happen again is one that can be fixed.")
    }
  }

  /// The one filled button, as on the passcode sheet and the Pro page, and a line under it saying
  /// where the message goes and that nothing has gone yet.
  private var footer: some View {
    VStack(spacing: 10) {
      Button(action: send) {
        Text("Send")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .frame(height: ChatStyle.control)
          .background(theme.sendFill, in: Capsule())
          .foregroundStyle(theme.sendGlyph)
      }
      .buttonStyle(.plain)
      .disabled(isEmpty(message))
      .opacity(isEmpty(message) ? 0.4 : 1)

      Text("Opens in your mail, to \(AppLinks.supportEmail). Nothing is sent until you send it there.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 24)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .background(Color(uiColor: .systemGroupedBackground))
  }

  // MARK: - The mail

  private func send() {
    focusedField = nil
    if MFMailComposeViewController.canSendMail() {
      composing = true
    } else if let url = AppLinks.mail(subject: subject, body: mailBody) {
      openURL(url) { accepted in
        if !accepted { showingNoMailApp = true }
      }
    } else {
      showingNoMailApp = true
    }
  }

  private var subject: String {
    kind == .feedback ? "Anvil feedback" : "Anvil bug"
  }

  /// What was written, each answer under its question, the empty ones left out, and the device
  /// line last when it is on.
  private var mailBody: String {
    var parts: [String]
    switch kind {
    case .feedback:
      parts = [message.trimmingCharacters(in: .whitespacesAndNewlines)]
    case .bug:
      parts = [
        answer("What happened", message),
        answer("What you expected", expected),
        answer("How to make it happen again", steps),
      ].compactMap { $0 }
    }
    if includesDetails { parts.append(deviceDetails) }
    return parts.joined(separator: "\n\n")
  }

  private func answer(_ question: String, _ text: String) -> String? {
    isEmpty(text) ? nil : "\(question):\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private func isEmpty(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// One line: the build, the phone and its iOS, the model in use, and whether Pro is active.
  /// Everything a bug report gets asked for, and nothing about the chats.
  private var deviceDetails: String {
    let model = library.active?.displayName ?? "no model"
    return "Sent from \(AppFlavor.appName) \(AppFlavor.version) on \(DeviceInfo.model), "
      + "iOS \(DeviceInfo.systemVersion), \(model), Pro \(pro.isUnlocked ? "on" : "off")"
  }
}

/// The system's mail sheet, addressed and filled in. SwiftUI has no view of its own for it.
private struct MailComposer: UIViewControllerRepresentable {
  let subject: String
  let body: String
  let onFinish: (MFMailComposeResult) -> Void

  func makeUIViewController(context: Context) -> MFMailComposeViewController {
    let composer = MFMailComposeViewController()
    composer.mailComposeDelegate = context.coordinator
    composer.setToRecipients([AppLinks.supportEmail])
    composer.setSubject(subject)
    composer.setMessageBody(body, isHTML: false)
    return composer
  }

  func updateUIViewController(_ composer: MFMailComposeViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
    let onFinish: (MFMailComposeResult) -> Void

    init(onFinish: @escaping (MFMailComposeResult) -> Void) {
      self.onFinish = onFinish
    }

    func mailComposeController(
      _ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult,
      error: Error?
    ) {
      onFinish(result)
    }
  }
}
