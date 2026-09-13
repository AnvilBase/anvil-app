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
  let model: ModelFile
  @Bindable var settings: SettingsStore
  /// Throwing the model away and starting again. It is the last resort for a model that won't
  /// load, and this is the only place it can be reached from.
  let onRemoveModel: () -> Void

  @Environment(ProAccess.self) private var pro
  @Environment(\.dismiss) private var dismiss
  @State private var confirmingDeleteAll = false

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
        appearanceSection
        securitySection
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

  private var proSection: some View {
    Section {
      NavigationLink {
        ProScreen()
      } label: {
        HStack(spacing: 12) {
          PixelAnvil(size: 20)
          Text("Anvil Pro")
          Spacer()
          Text(proStatus)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var proStatus: String {
    if pro.isUnlocked { return "Active" }
    if let price = pro.displayPrice { return "\(price) a month" }
    return ""
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

  private var modelSection: some View {
    Section("Model") {
      LabeledContent("Loaded", value: model.displayName)
      Button("Remove model", role: .destructive) {
        dismiss()
        onRemoveModel()
      }
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
      Picker("Appearance", selection: $settings.values.appearance) {
        ForEach(AppearancePreference.allCases) { preference in
          Text(preference.label).tag(preference)
        }
      }
      .pickerStyle(.segmented)

      proGated("Theme") {
        Picker("Theme", selection: $settings.values.theme) {
          ForEach(AppTheme.allCases) { theme in
            HStack(spacing: 10) {
              Circle()
                .fill(theme.swatch)
                .frame(width: 14, height: 14)
              Text(theme.label)
            }
            .tag(theme)
          }
        }
      }

      proGated("App icon") {
        Picker("App icon", selection: $settings.values.appIcon) {
          ForEach(AppIconChoice.allCases) { icon in
            HStack(spacing: 10) {
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(icon.colors.background)
                .frame(width: 22, height: 22)
                .overlay(PixelAnvil(size: 12, color: icon.colors.mark))
                .overlay(
                  RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
              Text(icon.label)
            }
            .tag(icon)
          }
        }
      }
    }
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
