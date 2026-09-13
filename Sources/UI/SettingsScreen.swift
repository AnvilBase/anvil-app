import SwiftUI

/// Everything you can change, in the order it matters: Pro, which model is loaded, what it is told,
/// what it remembers, how you talk to it, what it can reach, how long chats are kept, how it looks,
/// and whether it locks.
///
/// Short on purpose. Each section is its controls and nothing under them: a setting whose name
/// needs a paragraph is a setting with the wrong name. What Anvil Pro adds sits in the section it
/// belongs to — the prompt under System prompt, sampling under Generation — as the control itself
/// when Pro is active, and as the same row marked Pro, leading to the paywall, when it isn't.
struct SettingsScreen: View {
  let chat: ChatModel
  let library: ModelLibrary
  @Bindable var settings: SettingsStore

  @Environment(ProAccess.self) private var pro
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var confirmingDeleteAll = false
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
        if showsDevelopmentFeatures { metricsSection }
        generationSection
        historySection
        securitySection
        appearanceSection
        if AppFlavor.isDevelopment, !showsDevelopmentFeatures { backToDevelopmentSection }
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
    }
  }

  // MARK: - Pro

  /// The one row in Settings that is selling something, and it looks like it: the mark on its
  /// tile, the way it sits on the Home Screen, and a line of what Pro is. Still ink.
  private var proSection: some View {
    Section {
      NavigationLink {
        ProScreen()
      } label: {
        HStack(spacing: 14) {
          // Gold on black whatever the theme: this is the one thing in Settings that is for sale,
          // and it is allowed to look it.
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.black)
            .frame(width: 40, height: 40)
            .overlay(GoldAnvil(size: 24))
          VStack(alignment: .leading, spacing: 3) {
            Text("Anvil Pro")
              .font(.headline)
            Text(pro.isUnlocked ? "Active" : "Anvil Core · Prompt · Themes · Lock · Talk mode")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer()
          if !pro.isUnlocked, let price = pro.displayPrice {
            Text("\(price)/mo")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
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
  /// model — Anvil Core — is listed either way, and is the paywall's door rather than a model to
  /// switch to or download until Pro is active.
  private var modelSection: some View {
    Section("Model") {
      ForEach(library.installed) { file in
        Group {
          if file.isPro, !pro.isUnlocked {
            NavigationLink {
              ProScreen()
            } label: {
              LabeledContent(file.displayName) { proBadge }
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

  private var metricsSection: some View {
    Section("Metrics") {
      NavigationLink("Performance and usage") {
        MetricsScreen(chat: chat)
      }
    }
  }

  private var generationSection: some View {
    Section("Generation") {
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

      proGated("Theme") { themeChooser }
      proGated("App icon") { iconChooser }
    }
  }

  // MARK: - Choosing by looking

  /// The themes, each as a small page — its colour, a bubble, the one filled button — so what is
  /// being chosen is seen rather than named. Tap to choose; the ring marks the one in use.
  private var themeChooser: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Theme")
      ScrollView(.horizontal) {
        HStack(spacing: 14) {
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
        .padding(.vertical, 2)
      }
    }
  }

  /// The icons, as the icons: the mark on its tile in each of its colours.
  private var iconChooser: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("App icon")
      ScrollView(.horizontal) {
        HStack(spacing: 14) {
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
        .padding(.vertical, 2)
      }
    }
  }

  /// One choice: the preview, a ring when it is the one in use, and its name underneath. A plain
  /// button, so each is its own tap inside a row that holds several.
  private func swatch<Preview: View>(
    label: String, selected: Bool, action: @escaping () -> Void,
    @ViewBuilder preview: () -> Preview
  ) -> some View {
    Button(action: action) {
      VStack(spacing: 6) {
        preview()
          .frame(width: 58, height: 58)
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .strokeBorder(selected ? Color.primary : .clear, lineWidth: 2)
              .padding(-3))
        Text(label)
          .font(.caption)
          .foregroundStyle(selected ? Color.primary : Color.secondary)
      }
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

  private static func retentionLabel(_ days: Int) -> String {
    switch days {
    case 0: "Never"
    case 1: "1 day"
    default: "\(days) days"
    }
  }
}
