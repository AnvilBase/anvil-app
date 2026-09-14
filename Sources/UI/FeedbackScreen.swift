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
/// Each asks one thing — the feedback, or what happened — and, optionally, an address to answer
/// to. Both end with one line of device details — the build, the phone, iOS, the model in use,
/// whether Pro is on — shown in full under its switch, so what is included is never a surprise and
/// can be left off.
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
  /// Where an answer can go, if they want one. Optional: a report is welcome without it.
  @State private var email = ""
  @State private var includesDetails = true
  @State private var composing = false
  /// Set when the mail sheet reports the mail went, so the screen goes back to Settings once the
  /// sheet is down rather than while it is still closing.
  @State private var sent = false
  @State private var showingNoMailApp = false
  @FocusState private var focusedField: Field?

  private enum Field {
    case message
    case email
  }

  var body: some View {
    Form {
      switch kind {
      case .feedback: feedbackFields
      case .bug: bugFields
      }
      emailField

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

  private var bugFields: some View {
    Section("What happened") {
      TextField("What went wrong, and what you were doing", text: $message, axis: .vertical)
        .lineLimit(6...14)
        .focused($focusedField, equals: .message)
    }
  }

  /// An address to answer to, if they want an answer. The mail goes from their own account, so
  /// it is here for the mail apps that hide the sender, and for a report copied out by hand.
  private var emailField: some View {
    Section {
      TextField("Optional", text: $email)
        .keyboardType(.emailAddress)
        .textContentType(.emailAddress)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($focusedField, equals: .email)
    } header: {
      Text("Your email")
    } footer: {
      Text("If you'd like a reply.")
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

  /// What was written, the address to answer to when one was given, and the device line last
  /// when it is on.
  private var mailBody: String {
    var parts = [message.trimmingCharacters(in: .whitespacesAndNewlines)]
    if !isEmpty(email) {
      parts.append("Reply to: \(email.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    if includesDetails { parts.append(deviceDetails) }
    return parts.joined(separator: "\n\n")
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
