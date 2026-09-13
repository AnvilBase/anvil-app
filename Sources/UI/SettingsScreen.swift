import SwiftUI

/// Everything you can change, in the order it matters: Pro, which model is loaded, what it is told,
/// what it remembers, how you talk to it, what it can reach, how long chats are kept, how it looks,
/// and whether it locks. Then where to find people, how to tell us, and what the app is.
///
/// Short on purpose. Each section is its controls and nothing under them: a setting whose name
/// needs a paragraph is a setting with the wrong name. What Anvil Pro adds sits in the section it
/// belongs to — the prompt under System prompt, sampling under Personalization — as the control
/// itself when Pro is active, and as the same row marked Pro, leading to the paywall, when it isn't.
struct SettingsScreen: View {
  let chat: ChatModel
  let library: ModelLibrary
  @Bindable var settings: SettingsStore

  @Environment(ProAccess.self) private var pro
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var confirmingDeleteAll = false
  /// Shown when a mail row finds no mail app to hand its message to.
  @State private var showingNoMailApp = false
  /// What anvilai.com publishes, for the models that aren't on the phone yet.
  @State private var catalog: [CatalogModel] = []

  private var showsDevelopmentFeatures: Bool {
    AppFlavor.showsDevelopmentFeatures(settings.values)
  }

  var body: some View {
    NavigationStack {
      Form {
        proSection
        modelSection
        systemPromptSection
        memorySection
        voiceSection
        webSearchSection
        personalizationSection
        historySection
        securitySection
        appearanceSection
        if AppFlavor.isDevelopment, !showsDevelopmentFeatures { backToDevelopmentSection }
        communitySection
        feedbackSection
        aboutSection
      }
      .navigationTitle("Settings")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .confirmationDialog(
        "Delete all chats?", isPresented: $confirmingDeleteAll, titleVisibility: .visible
      ) {
        Button("Delete all chats", role: .destructive) { chat.deleteAllChats() }
      } message: {
        Text("This can't be undone.")
      }
      .alert("No mail app", isPresented: $showingNoMailApp) {
        #if os(iOS)
          Button("Copy address") { UIPasteboard.general.string = AppLinks.supportEmail }
        #endif
        Button("OK", role: .cancel) {}
      } message: {
        Text("Write to \(AppLinks.supportEmail) from wherever you do your mail.")
      }
    }
  }

  // MARK: - Pro

  /// The one row in Settings that is selling something: the gold mark and the name, larger than
  /// any other row, and nothing else. What Pro is, and what it costs, is the paywall's to say.
  private var proSection: some View {
    Section {
      NavigationLink {
        ProScreen()
      } label: {
        HStack(spacing: 16) {
          GoldAnvil(size: 36)
          Text("Anvil Pro")
            .font(.title2.weight(.bold))
        }
        .padding(.vertical, 6)
      }
    }
  }

  /// The small outline that marks a Pro row, in the shape Recommended takes on the model screen.
  private var proBadge: some View {
    Text("Pro")
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
  }

  /// A row that is the control when Pro is active and the paywall's door when it isn't. The locked
  /// row keeps the control's name and shows the badge where its value would be, so the list reads
  /// the same either way and nothing jumps when Pro arrives.
  @ViewBuilder
  private func proGated<Control: View>(
    _ title: String, @ViewBuilder control: () -> Control
  ) -> some View {
    if pro.isUnlocked {
      control()
    } else {
      NavigationLink {
        ProScreen()
      } label: {
        LabeledContent(title) { proBadge }
      }
    }
  }

  // MARK: - Sections

  /// The models on the phone, with a mark against the one in use; the ones that could be, with a
  /// way to get them; and the reload. Tap a model to switch to it, swipe one to delete it. A Pro
  /// model — Anvil Core, Anvil Dream — is listed either way, and is the paywall's door rather than
  /// a model to switch to or download until Pro is active. Anvil Dream is never switched to at
  /// all: it makes pictures beside whichever model is in use, and its row says so.
  private var modelSection: some View {
    Section("Models") {
      ForEach(library.installed) { file in
        Group {
          if file.isPro, !pro.isUnlocked {
            NavigationLink {
              ProScreen()
            } label: {
              LabeledContent(file.displayName) { proBadge }
            }
          } else if file.kind == .image {
            LabeledContent(file.displayName) {
              Text("Pictures")
                .foregroundStyle(.secondary)
            }
          } else {
            Button {
              guard file != library.active else { return }
              library.select(file)
              dismiss()
            } label: {
              HStack {
                Text(file.displayName)
                  .foregroundStyle(Color.primary)
                Spacer()
                if file == library.active {
                  Image(systemName: "checkmark")
                    .foregroundStyle(Color.secondary)
                }
              }
            }
          }
        }
        .swipeActions(edge: .trailing) {
          Button("Delete", role: .destructive) {
            Task {
              // The engine has the file open; let go of it before it goes.
              if file == library.active { await chat.unload() }
              if file.kind == .image { await chat.unloadImageModel() }
              await library.remove(file)
            }
          }
        }
      }
      ForEach(updates) { model in
        downloadRow(model, verb: "Update")
      }
      ForEach(available) { model in
        downloadRow(model, verb: "Download")
      }
      // Always here, not only when a setting has changed: this is also the way back from a model
      // that wouldn't load.
      Button {
        Task { await chat.reloadModel() }
        dismiss()
      } label: {
        Label("Reload model", systemImage: "arrow.clockwise")
          .foregroundStyle(Color.primary)
      }
    }
    .task { catalog = (try? await ModelCatalog.load()) ?? [] }
  }

  /// Catalog models that aren't on the phone at all.
  private var available: [CatalogModel] {
    catalog.filter { model in
      !library.installed.contains { $0.catalogID == model.id || $0.fileName == model.fileName }
    }
  }

  /// Catalog models the phone has an older version of. The catalog can change what a name means —
  /// a model re-based on something better — and the file name stays; the version is what moves.
  private var updates: [CatalogModel] {
    catalog.filter { model in
      library.installed.contains { $0.catalogID == model.id && $0.version != model.version }
    }
  }

  @ViewBuilder
  private func downloadRow(_ model: CatalogModel, verb: String) -> some View {
    let downloader = library.downloader
    if model.isPro, !pro.isUnlocked {
      NavigationLink {
        ProScreen()
      } label: {
        HStack {
          Label("\(verb) \(model.name)", systemImage: "arrow.down.circle")
            .foregroundStyle(Color.primary)
          Spacer()
          proBadge
        }
      }
    } else if downloader.model == model, downloader.isActive {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(model.name)
          Spacer()
          Text("\(Int(downloader.fraction * 100))%")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        ProgressView(value: downloader.fraction)
          .tint(theme.sendFill)
        Button("Cancel", role: .destructive) { Task { await library.cancelInstall() } }
          .font(.subheadline)
      }
    } else if downloader.model == model, case .failed(let message) = downloader.phase {
      VStack(alignment: .leading, spacing: 6) {
        Text(model.name)
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
        HStack(spacing: 16) {
          Button("Try again") { library.install(model) }
          Button("Start over", role: .destructive) { Task { await library.cancelInstall() } }
        }
        .font(.subheadline)
      }
    } else {
      Button {
        library.install(model)
      } label: {
        HStack {
          Label("\(verb) \(model.name)", systemImage: "arrow.down.circle")
            .foregroundStyle(Color.primary)
          Spacer()
          Text(model.formattedSize)
            .foregroundStyle(Color.secondary)
        }
      }
      .disabled(downloader.isActive)
    }
  }

  private var systemPromptSection: some View {
    Section("System prompt") {
      if pro.isUnlocked {
        TextField("System prompt", text: $settings.values.systemPrompt, axis: .vertical)
          .lineLimit(3...10)
        Button("Restore default") { settings.values.systemPrompt = AppSettings.defaultSystemPrompt }
          .disabled(settings.values.systemPrompt == AppSettings.defaultSystemPrompt)
      } else {
        NavigationLink {
          ProScreen()
        } label: {
          LabeledContent("Prompt") {
            HStack(spacing: 8) {
              Text("Default")
                .foregroundStyle(.secondary)
              proBadge
            }
          }
        }
      }
    }
  }

  private var memorySection: some View {
    Section("Memory") {
      Toggle("Memory", isOn: $settings.values.memoryEnabled)
      NavigationLink {
        MemoryScreen(memory: chat.memory)
      } label: {
        LabeledContent("Saved memories", value: chat.memory.items.count.formatted())
      }
    }
  }

  private var voiceSection: some View {
    Section("Voice") {
      Toggle("Send when you stop talking", isOn: $settings.values.autoSendVoice)
      proGated("Talk mode") {
        Toggle("Talk mode", isOn: $settings.values.talkMode)
      }
    }
  }

  private var webSearchSection: some View {
    Section("Web search") {
      Picker("Results per search", selection: $settings.values.webSearchResultCount) {
        ForEach(AppSettings.searchResultCounts, id: \.self) { count in
          Text("\(count)").tag(count)
        }
      }
    }
  }

  private var personalizationSection: some View {
    Section("Personalization") {
      Picker("Max reply length", selection: $settings.values.maxReplyTokens) {
        ForEach(AppSettings.replyLengthLimits, id: \.self) { limit in
          Text(limit == 0 ? "No limit" : "\(limit.formatted()) tokens").tag(limit)
        }
      }
      proGated("Sampling") { sampling }
    }
  }

  @ViewBuilder
  private var sampling: some View {
    Toggle("Use the model's default sampling", isOn: $settings.values.useModelSamplerDefaults)
      .onChange(of: settings.values.useModelSamplerDefaults) { _, useDefaults in
        // Start custom values from the model's own defaults rather than from nothing.
        if !useDefaults, let defaults = chat.modelDetails?.defaultSampler {
          settings.values.sampler = defaults
        }
      }
    if !settings.values.useModelSamplerDefaults {
      VStack(alignment: .leading) {
        LabeledContent(
          "Temperature", value: String(format: "%.2f", settings.values.sampler.temperature))
        Slider(value: $settings.values.sampler.temperature, in: 0...2, step: 0.05)
      }
      Stepper(
        "Top-K: \(settings.values.sampler.topK)", value: $settings.values.sampler.topK, in: 1...200)
      VStack(alignment: .leading) {
        LabeledContent("Top-P", value: String(format: "%.2f", settings.values.sampler.topP))
        Slider(value: $settings.values.sampler.topP, in: 0.05...1, step: 0.01)
      }
    }
    Toggle("Thinking", isOn: $settings.values.thinkingEnabled)
      .disabled(chat.modelDetails?.supportsThinking != true)
  }

  private var historySection: some View {
    Section("Chat history") {
      Picker("Delete chats after", selection: $settings.values.historyRetentionDays) {
        ForEach(AppSettings.retentionChoices, id: \.self) { days in
          Text(Self.retentionLabel(days)).tag(days)
        }
      }
      // Every chat as one file, handed to the share sheet: the way to keep them past the retention
      // period, or to take them somewhere else. The file is only written once a destination is
      // chosen; see ChatExport.
      ShareLink(item: ChatExport(chats: chat.savedChats), preview: SharePreview("Anvil chats")) {
        Label("Export chats", systemImage: "square.and.arrow.up")
          .foregroundStyle(Color.primary)
      }
      .disabled(chat.savedChats.isEmpty)
      Button("Delete all chats", role: .destructive) { confirmingDeleteAll = true }
        .disabled(chat.savedChats.isEmpty)
    }
  }

  private var appearanceSection: some View {
    Section("Appearance") {
      // The section is already called Appearance; a segmented picker in a Form would print its
      // own title above the control and say it twice.
      Picker("Appearance", selection: $settings.values.appearance) {
        ForEach(AppearancePreference.allCases) { preference in
          Text(preference.label).tag(preference)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      // The height of a row's control rather than the thin strip a segmented picker is by
      // default: it is the one control in the section you press rather than look at.
      .frame(height: ChatStyle.smallControl + 4)
      .padding(.vertical, 4)

      proGated("Theme") { themeChooser }
      proGated("App icon") { iconChooser }
    }
  }

  // MARK: - Choosing by looking

  /// The themes, each as a small page — its colour, a bubble, the one filled button — so what is
  /// being chosen is seen rather than named. Tap to choose; the one in use is the one in colour.
  private var themeChooser: some View {
    chooserRow("Theme") {
      ForEach(AppTheme.allCases) { choice in
        let palette = choice.palette
        swatch(
          label: choice.label, selected: settings.values.theme == choice,
          action: { settings.values.theme = choice }
        ) {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(palette.page)
            .overlay(alignment: .topLeading) {
              VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(palette.userBubble).frame(width: 30, height: 9)
                Capsule().fill(palette.userBubble).frame(width: 20, height: 9)
              }
              .padding(9)
            }
            .overlay(alignment: .bottomTrailing) {
              Circle().fill(palette.sendFill).frame(width: 14, height: 14).padding(8)
            }
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1))
        }
      }
    }
  }

  /// The icons, as the icons: the mark on its tile in each of its colours.
  private var iconChooser: some View {
    chooserRow("App icon") {
      ForEach(AppIconChoice.allCases) { choice in
        swatch(
          label: choice.label, selected: settings.values.appIcon == choice,
          action: { settings.values.appIcon = choice }
        ) {
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(choice.colors.background)
            .overlay {
              if choice == .pro {
                GoldAnvil(size: 32)
              } else {
                PixelAnvil(size: 30, color: choice.colors.mark)
              }
            }
            .overlay(
              RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.secondary.opacity(0.25), lineWidth: 0.5))
        }
      }
    }
  }

  /// The horizontal margin a Form gives its rows, matched by hand where a row is laid out edge to
  /// edge so that its text still lines up with the rows around it.
  private static let rowInset: CGFloat = 20

  /// A row of swatches to scroll sideways through. The scroll view runs the full width of the row
  /// rather than stopping at its margins, so nothing is cut off square where the margin would be:
  /// a swatch slides in and out through a short fade at either edge instead, and the first one
  /// starts where the row's text does.
  private func chooserRow<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .padding(.horizontal, Self.rowInset)
      ScrollView(.horizontal) {
        HStack(spacing: 14) { content() }
          .padding(.vertical, 2)
      }
      .contentMargins(.horizontal, Self.rowInset, for: .scrollContent)
      .mask(edgeFade)
    }
    .listRowInsets(EdgeInsets(top: 11, leading: 0, bottom: 11, trailing: 0))
  }

  /// Opaque across the row and clear at its two ends, over the width of the row's own margin: the
  /// edges of a sideways scroll fade rather than stop.
  private var edgeFade: some View {
    HStack(spacing: 0) {
      LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
        .frame(width: Self.rowInset)
      Color.black
      LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
        .frame(width: Self.rowInset)
    }
  }

  /// One choice: the preview and its name underneath. The one in use is shown as it is; the others
  /// are drained of colour and faded, so which is chosen is read from the swatches themselves and
  /// nothing has to be drawn around one. A plain button, so each is its own tap inside a row that
  /// holds several.
  private func swatch<Preview: View>(
    label: String, selected: Bool, action: @escaping () -> Void,
    @ViewBuilder preview: () -> Preview
  ) -> some View {
    Button(action: action) {
      VStack(spacing: 6) {
        preview()
          .frame(width: 58, height: 58)
          .saturation(selected ? 1 : 0)
          .opacity(selected ? 1 : 0.4)
        Text(label)
          .font(.caption)
          .foregroundStyle(selected ? Color.primary : Color.secondary)
      }
      .animation(.easeInOut(duration: 0.18), value: selected)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var securitySection: some View {
    Section("Security") {
      proGated("Face ID lock") {
        Toggle("Lock with Face ID or passcode", isOn: $settings.values.appLockEnabled)
          .disabled(!AppLock.isAvailable)
      }
    }
  }

  /// The way back out of showing the development app as the public one. It lives here because the
  /// hammer that would otherwise lead to it is one of the things being hidden, and Settings is
  /// always reachable. The public app never compiles a path to it: see the call site.
  private var backToDevelopmentSection: some View {
    Section("Developer") {
      Button("Show developer features again") {
        settings.values.previewAsPublic = false
        settings.save()
      }
    }
  }

  /// Where the people are. Each row leaves the app; the addresses live in `AppLinks`.
  private var communitySection: some View {
    Section("Community") {
      link("Discord", to: AppLinks.discord)
      link("X", to: AppLinks.x)
      link("Instagram", to: AppLinks.instagram)
    }
  }

  /// How to tell us. A rating goes to the App Store by way of the site; feedback and a bug report
  /// each start a mail, and the bug report arrives with the lines that make one answerable — what
  /// happened, and on which phone, iOS, build and model — already written, so the reply is never
  /// a question about those.
  private var feedbackSection: some View {
    Section("Feedback") {
      link("Rate Anvil", to: AppLinks.rate)
      mailRow("Send feedback", subject: "Anvil feedback", body: "\n\n\n\(diagnostics)")
      mailRow("Report a bug", subject: "Anvil bug", body: bugReportBody)
    }
  }

  /// The questions a bug report answers, with room under each, and the diagnostics line last.
  private var bugReportBody: String {
    "What happened:\n\n\nWhat you expected:\n\n\nHow to make it happen again:\n1. \n\n\n"
      + diagnostics
  }

  /// One line, for the foot of a mail: the build, the phone and its iOS, the model in use, and
  /// whether Pro is active. Everything a bug report gets asked for, and nothing about the chats.
  private var diagnostics: String {
    let model = library.active?.displayName ?? "no model"
    return "Sent from \(AppFlavor.appName) \(AppFlavor.version) on \(DeviceInfo.model), "
      + "iOS \(DeviceInfo.systemVersion), \(model), Pro \(pro.isUnlocked ? "on" : "off")"
  }

  /// A row that opens a mail to us, drawn like the link rows: it leaves the app the same way. If
  /// nothing on the phone takes mail, an alert gives the address instead.
  private func mailRow(_ title: String, subject: String, body: String) -> some View {
    Button {
      guard let url = AppLinks.mail(subject: subject, body: body) else { return }
      openURL(url) { accepted in
        if !accepted { showingNoMailApp = true }
      }
    } label: {
      HStack {
        Text(title)
          .foregroundStyle(Color.primary)
        Spacer()
        Image(systemName: "arrow.up.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Color.secondary)
      }
    }
  }

  /// What the app is bound by, and which one this is. Last, as it is in every app.
  private var aboutSection: some View {
    Section("About") {
      link("Terms & Conditions", to: AppLinks.terms)
      link("Privacy Policy", to: AppLinks.privacy)
      link("Licenses", to: AppLinks.licenses)
      LabeledContent("Version", value: AppFlavor.version)
    }
  }

  /// A row that opens a page in Safari. In ink like the rows around it rather than the tint a
  /// link takes on its own: leaving the app is not a bigger thing than any other row does.
  private func link(_ title: String, to url: URL) -> some View {
    Link(destination: url) {
      HStack {
        Text(title)
          .foregroundStyle(Color.primary)
        Spacer()
        Image(systemName: "arrow.up.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Color.secondary)
      }
    }
  }

  private static func retentionLabel(_ days: Int) -> String {
    switch days {
    case 0: "Never"
    case 1: "1 day"
    default: "\(days) days"
    }
  }
}
