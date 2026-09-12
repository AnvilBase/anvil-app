import SwiftUI

/// Everything you can change, in the order it matters: what the model is told, what it remembers,
/// how you talk to it, what it can reach, where it runs, and how long chats are kept.
struct SettingsScreen: View {
  let chat: ChatModel
  @Bindable var settings: SettingsStore

  @Environment(\.dismiss) private var dismiss
  @State private var confirmingDeleteAll = false

  var body: some View {
    NavigationStack {
      Form {
        systemPromptSection
        memorySection
        voiceSection
        webSearchSection
        metricsSection
        generationSection
        modelSection
        historySection
        if AppFlavor.isDevelopment {
          developerSection
        }
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

  private var systemPromptSection: some View {
    Section {
      TextField("System prompt", text: $settings.values.systemPrompt, axis: .vertical)
        .lineLimit(3...10)
      Button("Restore default") { settings.values.systemPrompt = AppSettings.defaultSystemPrompt }
        .disabled(settings.values.systemPrompt == AppSettings.defaultSystemPrompt)
    } header: {
      Text("System prompt")
    } footer: {
      Text(
        "Instructions the model follows in every reply. Used for new chats; each chat keeps the "
          + "prompt it started with.")
    }
  }

  private var memorySection: some View {
    Section {
      Toggle("Memory", isOn: $settings.values.memoryEnabled)
      NavigationLink {
        MemoryScreen(memory: chat.memory)
      } label: {
        LabeledContent("Saved memories", value: chat.memory.items.count.formatted())
      }
    } header: {
      Text("Memory")
    } footer: {
      Text(
        "When on, \(AppFlavor.appName) remembers details you share, like your name or preferences, "
          + "and uses them in new chats. Memories are stored only on this iPhone.")
    }
  }

  private var voiceSection: some View {
    Section {
      Toggle("Send when you stop talking", isOn: $settings.values.autoSendVoice)
    } header: {
      Text("Voice input")
    } footer: {
      Text(
        "Tap the microphone to talk and your words are typed into the message field. Speech is "
          + "recognized on this iPhone and the audio never leaves it. Replies are never read aloud.")
    }
  }

  private var webSearchSection: some View {
    Section {
      Toggle(
        "Web search",
        isOn: Binding(get: { chat.webSearchOn }, set: { settings.values.webSearchEnabled = $0 })
      )
      .disabled(!chat.hasSearchKey || chat.isOffline)

      if !chat.hasSearchKey {
        Text(
          "This build has no Brave Search key, so web search is unavailable. Add one in "
            + "Config/Local.xcconfig and rebuild."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      } else if chat.isOffline {
        Text("Internet connection is offline, so web search is unavailable.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Picker("Results per search", selection: $settings.values.webSearchResultCount) {
        ForEach(AppSettings.searchResultCounts, id: \.self) { count in
          Text("\(count)").tag(count)
        }
      }
    } header: {
      Text("Web search")
    } footer: {
      Text(
        "When on, the model can search the web with Brave Search if it needs current information. "
          + "Only the queries it writes are sent to Brave; your chats stay on this iPhone. More "
          + "results use more of the model's context.")
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
    Section {
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

      Picker("Max reply length", selection: $settings.values.maxReplyTokens) {
        ForEach(AppSettings.replyLengthLimits, id: \.self) { limit in
          Text(limit == 0 ? "No limit" : "\(limit.formatted()) tokens").tag(limit)
        }
      }

      Toggle("Thinking", isOn: $settings.values.thinkingEnabled)
        .disabled(chat.modelDetails?.supportsThinking != true)
    } header: {
      Text("Generation")
    } footer: {
      Text(generationFooter)
    }
  }

  private var generationFooter: String {
    var text = "Lower temperature gives focused, predictable answers; higher gives more varied ones. "
    if chat.modelDetails?.supportsThinking == true {
      text += "Thinking lets the model reason before answering (slower, uses more context). "
    } else if chat.modelDetails != nil {
      text += "This model doesn't support thinking. "
    }
    return text + "Changes apply from your next message."
  }

  private var modelSection: some View {
    Section {
      Picker("Backend", selection: $settings.values.engine.backend) {
        ForEach(EngineBackendPreference.allCases) { preference in
          Text(preference.label).tag(preference)
        }
      }
      Picker("Context size", selection: $settings.values.engine.contextSize) {
        ForEach(AppSettings.contextSizes, id: \.self) { size in
          Text("\(size.formatted()) tokens").tag(size)
        }
      }
      Toggle("Image input", isOn: $settings.values.engine.imageInput)

      if chat.needsReload {
        Button("Reload model to apply") {
          Task { await chat.reloadModel() }
          dismiss()
        }
      }
    } header: {
      Text("Model")
    } footer: {
      Text(
        "Settings for the model on this iPhone. A larger context remembers more of the chat but "
          + "uses more memory; if iOS closes the app, go back to 4,096. Turning off image input "
          + "saves memory too.")
    }
  }

  private var historySection: some View {
    Section {
      Picker("Delete chats after", selection: $settings.values.historyRetentionDays) {
        ForEach(AppSettings.retentionChoices, id: \.self) { days in
          Text(Self.retentionLabel(days)).tag(days)
        }
      }
      Button("Delete all chats", role: .destructive) { confirmingDeleteAll = true }
        .disabled(chat.savedChats.isEmpty)
    } header: {
      Text("Chat history")
    } footer: {
      Text(
        "Chats stay on this iPhone, can't be read while it's locked, and aren't included in "
          + "backups. A chat is deleted this long after its last message.")
    }
  }

  /// Only in the development app.
  private var developerSection: some View {
    Section {
      NavigationLink("Developer") {
        DeveloperScreen(chat: chat)
      }
    } footer: {
      Text("Shown in the development build only.")
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
