import StoreKit
import SwiftUI

/// Everything you can change, as a short list of pages: Pro first, then which model is loaded,
/// how the chat behaves, how you talk to it, how long chats are kept, how it looks, and whether
/// it locks. Then where to find people, how to tell us, and what the app is. Each row opens a page
/// that holds one group and nothing else, so the first screen is read in a glance and no page
/// asks to be scrolled.
///
/// It was one long form once, every group stacked on the last, and the thing you came for was
/// always somewhere below the fold. The groups are the same; they are simply behind their names.
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
  /// Apple's own rating prompt, the stars over the page, asked for by Rate Anvil.
  @Environment(\.requestReview) private var requestReview
  @State private var confirmingDeleteAll = false
  /// The passcode being set or changed, while its sheet is up.
  @State private var passcodeSheet: PasscodeSheet.Mode?
  /// The Pro page, pushed when a theme or an icon that needs Pro is chosen without it.
  @State private var showingProForChoice = false
  /// What anvilai.com publishes, for the models that aren't on the phone yet.
  @State private var catalog: [CatalogModel] = []
  @State private var freeBytes: Int64?
  @State private var capacityBytes: Int64?
  /// What the engines have cached beside the models — see `ModelFiles.cacheDirectory`.
  @State private var cacheBytes: Int64 = 0

  private var storageAlertShowing: Binding<Bool> {
    Binding(
      get: { library.storageWarning != nil },
      set: { if !$0 { library.storageWarning = nil } })
  }

  private var showsDevelopmentFeatures: Bool {
    AppFlavor.showsDevelopmentFeatures(settings)
  }

  var body: some View {
    NavigationStack {
      Form {
        proSection
        Section {
          page("Models", systemImage: "cpu", badge: proAwaitsDownload, load: loadCatalog) {
            modelSection
            imageSection
            storageSection
          }
          page("Chat", systemImage: "text.bubble") {
            systemPromptSection
            memorySection
            personalizationSection
            webSearchSection
          }
          page("Voice", systemImage: "waveform") { voiceSection }
          page("Chat history", systemImage: "clock.arrow.circlepath") { historySection }
        }
        Section {
          page("Appearance", systemImage: "paintpalette") { appearanceSection }
          page("Security", systemImage: "lock") { securitySection }
        }
        Section {
          page("Community", systemImage: "person.2") { communitySection }
          page("Feedback", systemImage: "envelope") { feedbackSection }
          page("About", systemImage: "info.circle") { aboutSection }
        }
        if showsDevelopmentFeatures { developerSection }
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
    .alert("Not enough storage on your phone", isPresented: storageAlertShowing) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(library.storageWarning ?? "")
    }
      // Up here with the dialog and the alerts, not on the Security section. A modifier on a Form
      // section lands on each of its rows, so the sheet was presented from inside a list cell, and
      // the first time it was, Settings closed instead of the sheet opening over it.
      .sheet(item: $passcodeSheet) { mode in
        PasscodeSheet(mode: mode) {
          settings.appLockEnabled = true
          settings.save()
        }
      }
      .navigationDestination(isPresented: $showingProForChoice) { ProScreen() }
    }
  }

  /// One group on a page of its own, behind a row on the first screen. The page is a form like
  /// the first screen, with the group's own sections in it, and the row is the page's name with
  /// its mark in front — in the row's ink, as the Community and Feedback rows have theirs.
  private func page<Content: View>(
    _ title: String, systemImage: String, badge: Bool = false,
    load: (@Sendable () async -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    NavigationLink {
      Form { content() }
        // Whatever the page needs fetched, asked for by the page itself. A `.task` on a
        // section is a task on each of its rows, so a section that starts empty — the models,
        // before the catalog has arrived — never runs it, and the page that was waiting for
        // the catalog to fill it waited for ever.
        .task { await load?() }
        .navigationTitle(title)
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
    } label: {
      HStack {
        // In the row's ink, not the tint a link's symbol takes on its own: the mark names the
        // page, it doesn't act, and nothing here should be louder than the words beside it.
        Label(title, systemImage: systemImage)
          .foregroundStyle(Color.primary)
        Spacer()
        // The one thing louder than the words: a page with something waiting on it — Anvil
        // Pro paid for and not yet on the phone — says so from here, before it is opened.
        if badge { attentionBadge }
      }
    }
  }

  /// The green mark that says a row has something waiting behind it: something to get, not
  /// something wrong.
  private var attentionBadge: some View {
    Image(systemName: "exclamationmark.circle.fill")
      .foregroundStyle(.green)
      .accessibilityLabel("Needs attention")
  }

  /// Pro is paid for and what it unlocks isn't on the phone — Anvil Pro, Anvil Dream, or both —
  /// and nothing is on its way. Someone who bought Pro and never downloaded its models has a
  /// subscription doing nothing, and the badge on the Models row is how they find out where to go.
  private var proAwaitsDownload: Bool {
    guard pro.isUnlocked, !library.isDownloading else { return false }
    let hasChat = library.installed.contains { $0.isPro && $0.kind == .text }
    let hasPictures = library.installed.contains { $0.isPro && $0.kind == .image }
    return !(hasChat && hasPictures)
  }

  // MARK: - Pro

  /// The one row in Settings that is selling something: the gold mark and the name, larger than
  /// any other row, and nothing else. What Pro is, and what it costs, is the paywall's to say.
  /// Once Pro is active there is nothing left to sell, so the row stops being a door: the small
  /// mark and "Anvil Pro Active", a statement in the size of any other row, and nothing to press.
  private var proSection: some View {
    Section {
      if pro.isUnlocked {
        HStack(spacing: 12) {
          GoldAnvil(size: 22)
          Text("Anvil Pro Active")
        }
        .accessibilityElement(children: .combine)
      } else {
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
  }

  /// The small outline that marks a Pro row, in the shape Recommended takes on the model screen.
  private var proBadge: some View { capsule("Pro") }

  private func capsule(_ text: String) -> some View {
    Text(text)
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

  /// The three things Anvil offers, one row each — Anvil Core, Anvil Pro and Anvil Dream —
  /// whatever state each is in: on the phone with a mark against the one in use, waiting to be downloaded, or announced
  /// and not published yet. A model the catalog doesn't know, one imported by hand, comes after
  /// them. Tap a model to switch to it, swipe one to delete it. The two that need Pro are listed
  /// either way, and are the paywall's door rather than models to switch to or download until Pro
  /// is active. Whether pictures get made at all is a switch rather than a model: see
  /// `imageSection`.
  private var modelSection: some View {
    Section("Text Models") {
      ForEach(modelRows) { row in modelRow(row) }
    }
  }

  /// What anvilai.com publishes, and the names the models go by now. Asked for by the Models
  /// page as a whole, so it runs whether or not any section on it has a row yet.
  @Sendable private func loadCatalog() async {
    catalog = (try? await ModelCatalog.load()) ?? []
    await library.adoptNames(from: catalog)
  }

  /// What anvilai.com publishes, read as the two things on offer.
  private var plans: [ModelPlan] { ModelPlan.plans(from: catalog) }

  /// What the app holds on the phone: the models and their cache on one bar, as two bands
  /// of the same ink — the models darker, the cache lighter — and the caption saying each.
  /// A model is the largest thing the app puts on a phone, and this is where to say so. The
  /// caches keep themselves — whatever isn't a model's own goes on its own
  /// (`ModelFiles.pruneCaches`) — so the row reports and nothing more.
  private var storageSection: some View {
    Section("Storage") {
      VStack(alignment: .leading, spacing: 8) {
        Text("Total storage")
          .task(id: library.installed) {
            freeBytes = DeviceStorage.free()
            capacityBytes = DeviceStorage.capacity()
            cacheBytes = await Task.detached { ModelFiles.cacheBytes() }.value
          }
        // The two together are what iOS counts against the app: the bar says the number
        // Settings › Storage says, in two parts.
        StorageBar(
          needed: installedModelBytes + cacheBytes, free: freeBytes, capacity: capacityBytes,
          installedCaption: cacheBytes > 0
            ? "\(Self.format(installedModelBytes)) of models · \(Self.format(cacheBytes)) of cache"
            : "\(Self.format(installedModelBytes)) of models",
          cache: cacheBytes,
          isProposed: false)
      }
    }
  }

  /// Everything the models take together — a text model is a file, an image model a
  /// folder, and `ModelFile` already carries the size of either.
  private var installedModelBytes: Int64 {
    library.installed.reduce(0) { $0 + $1.fileSize }
  }

  private static func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  /// Pictures, which Anvil Pro makes: one switch, and only once there is something to switch. It
  /// is not a model to choose between — it works beside whichever model the chat is on — so it is
  /// a setting rather than a row under Models. Off, the model stays on the phone, nothing makes a
  /// picture with it, and the memory it had loaded is let go.
  private var imageSection: some View {
    // Always here. Without Pro the row keeps its name and wears the badge where the switch
    // would be, leading to the paywall like every other locked row: what the app can do
    // shouldn't be invisible until it is paid for.
    Section("Image Models") {
      // The models that make pictures, in the catalog's order — Anvil Dream Lite, smaller and
      // quicker, then Anvil Dream — listed whether or not Pro is active, the way the chat
      // models are: each what it costs to download, how far it has got, or here with a mark
      // against the one in use; without Pro, the door to the page that sells it. Tap one to
      // paint with it, swipe to take it off the phone. Both can be here; one paints.
      ForEach(plans.filter(\.isImage)) { plan in
        imageModelRow(plan)
      }
      proGated("Image generation") {
        // The switch, under the models it serves. With Pro but before a download has landed,
        // it is there, off, faded and can't be thrown: there is nothing yet for it to switch
        // on, and a switch that says On over a model that isn't on the phone is a promise the
        // next message breaks. The setting itself is left alone, so the switch comes back to
        // what it was set to once a model is here.
        let dreamIsHere = library.imageModel != nil
        Toggle(
          "Image generation",
          isOn: dreamIsHere ? $settings.imageGenerationEnabled : .constant(false)
        )
        .disabled(!dreamIsHere)
        // The same fade a locked card wears on the install screen.
        .opacity(dreamIsHere ? 1 : 0.55)
        .onChange(of: settings.imageGenerationEnabled) { _, on in
          if !on { Task { await chat.unloadImageModel() } }
        }
      }
    }
  }

  @ViewBuilder
  private func modelRow(_ row: ModelRow) -> some View {
    switch row {
    case .plan(let plan): planRow(plan)
    case .file(let file): fileRow(file)
    }
  }

  private enum ModelRow: Identifiable {
    /// One of the things the catalog offers: Anvil Core, or Anvil Pro.
    case plan(ModelPlan)
    /// A model on the phone that the catalog doesn't know — one imported by hand.
    case file(ModelFile)

    var id: String {
      switch self {
      case .plan(let plan): "plan-\(plan.id)"
      case .file(let file): "file-\(file.fileName)"
      }
    }
  }

  /// The rows in the order the catalog gives them, with whatever the catalog doesn't know after.
  private var modelRows: [ModelRow] {
    // The chat models. The picture model has its row in the Image section, beside the switch
    // that turns it on.
    let offered = plans.filter { !$0.isImage }
    var rows = offered.map(ModelRow.plan)
    let accounted = Set(offered.flatMap { library.installedFiles(of: $0) })
    for file in library.installed where !accounted.contains(file) && file.kind == .text {
      rows.append(.file(file))
    }
    return rows
  }

  /// One of the two, in whatever state it is in.
  @ViewBuilder
  private func planRow(_ plan: ModelPlan) -> some View {
    if plan.isPro, !pro.isUnlocked {
      // Listed whether or not its file is on the phone, and the door to the page that sells it:
      // what Pro is for is the thing that can't be had yet. The model that is Pro's namesake
      // says what pressing it is; the picture model keeps its name and wears the badge.
      NavigationLink {
        ProScreen()
      } label: {
        LabeledContent { proBadge } label: {
          Text(plan.textModel != nil ? "Upgrade to \(plan.name) Model" : plan.name)
        }
      }
    } else if library.isInstalled(plan) {
      installedRow(plan)
      // The catalog can change what a name means — a model re-based on something better — and the
      // file name stays; the version is what moves.
      if library.hasUpdate(for: plan) {
        downloadRow(plan, update: true)
      }
    } else if plan.isComingSoon {
      LabeledContent { Text("Coming soon").foregroundStyle(.secondary) } label: { Text(plan.name) }
    } else {
      downloadRow(plan)
    }
  }

  /// One picture model's row in the Image section: its download, its progress, or — on the
  /// phone — its name with a mark against it if it is the one that paints. Tap to paint with it,
  /// swipe to delete it.
  @ViewBuilder
  private func imageModelRow(_ plan: ModelPlan) -> some View {
    if plan.isPro, !pro.isUnlocked, plan.fitsThisPhone {
      // Listed whether or not its file is on the phone, and the door to the page that sells it.
      NavigationLink {
        ProScreen()
      } label: {
        LabeledContent { proBadge } label: { Text(plan.name) }
      }
    } else if !plan.fitsThisPhone {
      // A model this phone hasn't the memory for: named, with what it needs where its size
      // would be, and nothing to press. On the phone already — downloaded before the catalog
      // said — it can be swiped away, and is never painted with.
      LabeledContent(plan.name) {
        Text("Needs \(plan.formattedMinimumMemory ?? "more") memory")
          .foregroundStyle(.secondary)
      }
      .swipeActions(edge: .trailing) {
        if library.isInstalled(plan) {
          Button("Delete", role: .destructive) {
            Task { await library.remove(plan) }
          }
        }
      }
    } else if library.isInstalled(plan) {
      Button {
        guard !library.isActiveImage(plan) else { return }
        library.selectImage(plan)
        // The other model, if it was loaded, goes; the chosen one loads at the next picture.
        Task { await chat.unloadImageModel() }
      } label: {
        HStack {
          Text(plan.name)
            .foregroundStyle(Color.primary)
          Spacer()
          if library.isActiveImage(plan) {
            Image(systemName: "checkmark")
              .foregroundStyle(Color.secondary)
          }
        }
      }
      .swipeActions(edge: .trailing) {
        Button("Delete", role: .destructive) {
          Task {
            if library.isActiveImage(plan) { await chat.unloadImageModel() }
            await library.remove(plan)
          }
        }
      }
      if library.hasUpdate(for: plan) {
        downloadRow(plan, update: true)
      }
    } else if plan.isComingSoon {
      LabeledContent(plan.name) { Text("Coming soon").foregroundStyle(.secondary) }
    } else {
      downloadRow(plan)
    }
  }

  /// A model that is on the phone: tap to run the chat on it, swipe to delete it.
  private func installedRow(_ plan: ModelPlan) -> some View {
    Button {
      guard !library.isActive(plan) else { return }
      library.select(plan)
      dismiss()
    } label: {
      HStack {
        Text(plan.name)
          .foregroundStyle(Color.primary)
        Spacer()
        if library.isActive(plan) {
          Image(systemName: "checkmark")
            .foregroundStyle(Color.secondary)
        }
      }
    }
    .swipeActions(edge: .trailing) {
      Button("Delete", role: .destructive) {
        Task {
          // The engine has the files open; let go of them before they go.
          if library.isActive(plan) { await chat.unload() }
          if plan.imageModel != nil { await chat.unloadImageModel() }
          await library.remove(plan)
        }
      }
    }
  }

  /// A model file no plan claims: one imported by hand, or — before the catalog has arrived — one
  /// the app downloaded and can't place yet. It goes under the rows that are plans, named the way
  /// the app names it rather than the way the file is.
  private func fileRow(_ file: ModelFile) -> some View {
    Button {
      guard file != library.active else { return }
      library.select(file)
      dismiss()
    } label: {
      HStack {
        Text(file.spokenName)
          .foregroundStyle(Color.primary)
        Spacer()
        if file == library.active {
          Image(systemName: "checkmark")
            .foregroundStyle(Color.secondary)
        }
      }
    }
    .swipeActions(edge: .trailing) {
      Button("Delete", role: .destructive) {
        Task {
          if file == library.active { await chat.unload() }
          await library.remove(file)
        }
      }
    }
  }

  /// A model that could be on the phone. Its row is its name — the arrow beside it says what
  /// tapping does — and what it costs in space; an update says so where the size would be.
  @ViewBuilder
  private func downloadRow(_ plan: ModelPlan, title: String? = nil, update: Bool = false) -> some View {
    let downloader = library.downloader(for: plan)
    let name = title ?? plan.name
    // What pressing it costs, which is what is left to fetch rather than what the plan weighs.
    let remaining = library.remainingSize(of: plan)
    let cost =
      remaining > 0
      ? ByteCountFormatter.string(fromByteCount: remaining, countStyle: .file) : plan.formattedSize
    let detail =
      library.isInterrupted(plan)
      ? "Resume" : (update ? "Update · \(plan.formattedSize)" : cost)
    if let downloader, downloader.isActive {
      // Its own view: the bar moves several times a second, and only the row should move
      // with it, not the whole form under a scrolling thumb.
      DownloadingRow(plan: plan, title: name, library: library, downloader: downloader)
    } else if let downloader, case .failed(let message) = downloader.phase {
      VStack(alignment: .leading, spacing: 6) {
        Text(name)
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
        HStack(spacing: 16) {
          // Try again picks up where it stopped: what has already landed is not fetched twice.
          Button("Try again") { library.install(plan) }
          Button("Start over", role: .destructive) { Task { await library.cancelInstall(plan) } }
        }
        .font(.subheadline)
        // Two buttons on one row: with the default style a tap on the row would press both, or
        // neither. Borderless, each takes only its own.
        .buttonStyle(.borderless)
      }
    } else {
      // The model that makes pictures waits for a model to chat with.
      let waitsForChatModel = plan.textModel == nil && !library.hasTextModel
      Button {
        library.install(plan)
      } label: {
        HStack {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(name)
                // The same mark the Models row wore on the way here: this is a row it meant.
                if plan.isPro, proAwaitsDownload { attentionBadge }
              }
            }
          } icon: {
            Image(systemName: "arrow.down.circle")
          }
          .foregroundStyle(waitsForChatModel ? Color.secondary : Color.primary)
          Spacer()
          Text(waitsForChatModel ? "Needs a chat model" : detail)
            .foregroundStyle(Color.secondary)
        }
      }
      .disabled(waitsForChatModel)
      // The same reading the install screen gives, for the same decision made here.
      StorageBar(
        needed: library.peakBytes(of: plan), keeps: library.keptBytes(of: plan),
        free: freeBytes, capacity: capacityBytes)
        .listRowSeparator(.hidden, edges: .top)
    }
  }

  /// The field holds a prompt of your own and nothing else: empty, it reads Default, and that is
  /// the whole of what is shown of Anvil's own prompt. Restore default empties it. One line while
  /// it is empty, and as many as the words need after that, up to ten; a hundred words and five
  /// line breaks at most, with the word count under the field once there is something to count.
  private var systemPromptSection: some View {
    Section {
      if pro.isUnlocked {
        TextField("Default", text: $settings.systemPrompt, axis: .vertical)
          .lineLimit(1...10)
          .onChange(of: settings.systemPrompt) { _, text in
            let limited = AppSettings.withinPromptLimit(text)
            if limited != text { settings.systemPrompt = limited }
          }
        Button("Restore default") { settings.systemPrompt = "" }
          .disabled(usesDefaultPrompt)
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
    } header: {
      Text("System prompt")
    } footer: {
      if pro.isUnlocked, !usesDefaultPrompt {
        Text(
          "\(AppSettings.wordCount(settings.systemPrompt)) of "
            + "\(AppSettings.maxSystemPromptWords) words")
      }
    }
  }

  private var usesDefaultPrompt: Bool {
    settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var memorySection: some View {
    Section("Memory") {
      Toggle("Memory", isOn: $settings.memoryEnabled)
      NavigationLink {
        MemoryScreen(memory: chat.memory)
      } label: {
        LabeledContent("Saved memories", value: chat.memory.items.count.formatted())
      }
    }
  }

  private var voiceSection: some View {
    Section("Voice") {
      NavigationLink {
        VoicePickerScreen(settings: settings, speech: chat.speechOutput)
      } label: {
        LabeledContent("Voice", value: currentVoiceName)
      }
      Toggle("Send when you stop talking", isOn: $settings.autoSendVoice)
    }
  }

  /// The voice replies are read in, by name — what "Automatic" resolved to as much as a choice.
  private var currentVoiceName: String {
    SpeechVoices.voice(for: settings.voiceIdentifier)?.name ?? "None"
  }

  private var webSearchSection: some View {
    Section("Web search") {
      Picker("Results per search", selection: $settings.webSearchResultCount) {
        ForEach(AppSettings.searchResultCounts, id: \.self) { count in
          Text("\(count)").tag(count)
        }
      }
    }
  }

  private var personalizationSection: some View {
    Section("Personalization") {
      Picker("Max reply length", selection: $settings.maxReplyTokens) {
        ForEach(AppSettings.replyLengthLimits, id: \.self) { limit in
          Text(limit == 0 ? "No limit" : "\(limit.formatted()) tokens").tag(limit)
        }
      }
      proGated("Sampling") { sampling }
    }
  }

  @ViewBuilder
  private var sampling: some View {
    Toggle("Use the model's default sampling", isOn: $settings.useModelSamplerDefaults)
      .onChange(of: settings.useModelSamplerDefaults) { _, useDefaults in
        // Start custom values from the model's own defaults rather than from nothing.
        if !useDefaults, let defaults = chat.modelDetails?.defaultSampler {
          settings.sampler = defaults
        }
      }
    if !settings.useModelSamplerDefaults {
      VStack(alignment: .leading) {
        LabeledContent(
          "Temperature", value: String(format: "%.2f", settings.sampler.temperature))
        Slider(value: $settings.sampler.temperature, in: 0...2, step: 0.05)
      }
      Stepper(
        "Top-K: \(settings.sampler.topK)", value: $settings.sampler.topK, in: 1...200)
      VStack(alignment: .leading) {
        LabeledContent("Top-P", value: String(format: "%.2f", settings.sampler.topP))
        Slider(value: $settings.sampler.topP, in: 0.05...1, step: 0.01)
      }
    }
  }

  private var historySection: some View {
    Section("Chat history") {
      Picker("Delete chats after", selection: $settings.historyRetentionDays) {
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
      // As tall as an inline control — it is the one control in the section you press rather than
      // look at — which the system's segmented picker refuses to be: it keeps its own thin height
      // inside whatever frame it is given. So the control is the app's own.
      SegmentedControl(AppearancePreference.allCases, selection: $settings.appearance) {
        $0.label
      }
      .padding(.vertical, 4)
      .accessibilityLabel("Appearance")

      // Seen by everyone, and set only with Pro: without it the row carries the Pro mark, and a
      // theme or icon that needs Pro leads to the Pro page rather than taking. What is on offer
      // is worth looking at before paying for it.
      themeChooser
      iconChooser
    }
  }

  // MARK: - Choosing by looking

  /// The themes, each as a small page — its colour, a bubble, the one filled button — so what is
  /// being chosen is seen rather than named. Tap to choose; the one in use is the one in colour.
  private var themeChooser: some View {
    chooserRow("Theme", locked: !pro.isUnlocked) {
      ForEach(AppTheme.allCases) { choice in
        let palette = choice.palette
        swatch(
          label: choice.label, selected: settings.theme == choice,
          action: { choose(choice.isFree) { settings.theme = choice } }
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

  /// The icons, as the icons: the mark on its tile in each of its colours. Pro's is the mark in
  /// gold, flat, on the same black as the rest; the modelled block is the Pro page's alone.
  private var iconChooser: some View {
    chooserRow("App icon", locked: !pro.isUnlocked) {
      ForEach(AppIconChoice.allCases) { choice in
        swatch(
          label: choice.label, selected: settings.appIcon == choice,
          action: { choose(choice == .anvil) { settings.appIcon = choice } }
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
  /// Takes a choice: the free one always, the rest only with Pro — without it the Pro page comes
  /// up instead, with the choice one purchase away.
  private func choose(_ free: Bool, _ set: () -> Void) {
    if free || pro.isUnlocked {
      set()
    } else {
      showingProForChoice = true
    }
  }

  private func chooserRow<Content: View>(
    _ title: String, locked: Bool = false, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(title)
        if locked { proBadge }
      }
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

  /// One choice: the preview and its name underneath. Every one keeps its colour — the colours are
  /// what is being chosen between — and the one in use is the bright one: lit a touch and at full
  /// strength, the others dimmed, so which is chosen is read from the swatches themselves and
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
          .brightness(selected ? 0.08 : 0)
          .opacity(selected ? 1 : 0.6)
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

  /// The lock: a passcode of the app's own, set here, asked for whenever the app comes back to the
  /// screen. Turning the switch on opens the sheet that sets the passcode, and the switch only
  /// stays on once one is saved; turning it off forgets the passcode. There is no recovery, and
  /// the footer says so before anyone needs it.
  private var securitySection: some View {
    Section {
      proGated("Passcode lock") {
        Toggle("Lock with a passcode", isOn: lockBinding)
        if lockBinding.wrappedValue {
          Button("Change passcode") { passcodeSheet = .change }
        }
      }
    } header: {
      Text("Security")
    } footer: {
      if pro.isUnlocked, lockBinding.wrappedValue {
        Text(
          "Anvil locks whenever it leaves the screen. If you forget the passcode, the only way back "
            + "in is to delete the app and install it again.")
      }
    }
  }

  /// On only when asked for and a passcode exists to lock behind; switching it on goes through
  /// the sheet, and switching it off clears the passcode so a stale one can't lock a later switch-on.
  private var lockBinding: Binding<Bool> {
    Binding(
      get: { settings.appLockEnabled && AppLock.hasPasscode },
      set: { on in
        if on {
          passcodeSheet = .set
        } else {
          settings.appLockEnabled = false
          settings.save()
          AppLock.clearPasscode()
        }
      })
  }

  /// The developer screen, at the very bottom, where the development app keeps what the public
  /// app doesn't have. It used to be a hammer in the chat's top bar; that spot is voice mode's now.
  private var developerSection: some View {
    Section {
      NavigationLink {
        DeveloperScreen(chat: chat, library: library)
          .scrollIndicators(.hidden)
      } label: {
        Label("Developer", systemImage: "hammer")
      }
    }
  }

  /// Where the people are. Each row leaves the app; the addresses live in `AppLinks`.
  private var communitySection: some View {
    Section("Community") {
      link("Discord", image: "Discord", to: AppLinks.discord)
      link("X", image: "X", to: AppLinks.x)
      link("Instagram", image: "Instagram", to: AppLinks.instagram)
    }
  }

  /// How to tell us. Rate Anvil asks iOS for its own rating prompt — the five stars over the page,
  /// the way every app asks — and stays on the page; iOS decides whether to show it, and shows it
  /// a few times a year at most, so a press that seems to do nothing has been heard. Write a
  /// review goes to the App Store page, where the words go. Feedback and a bug report each open a
  /// page of their own, written in the app and sent from the mail sheet. The in-app rows carry
  /// the chevron of a page; the App Store row, the arrow of a link.
  private var feedbackSection: some View {
    Section("Feedback") {
      Button {
        requestReview()
      } label: {
        Label("Rate Anvil", systemImage: "star")
          .foregroundStyle(Color.primary)
      }
      link("Write a review", systemImage: "square.and.pencil", to: AppLinks.review)
      NavigationLink {
        FeedbackScreen(kind: .feedback, library: library)
      } label: {
        Label("Send feedback", systemImage: "envelope")
          .foregroundStyle(Color.primary)
      }
      NavigationLink {
        FeedbackScreen(kind: .bug, library: library)
      } label: {
        Label("Report a bug", systemImage: "ant")
          .foregroundStyle(Color.primary)
      }
    }
  }

  /// Why the app is, what it is bound by, and which one this is. Last, as it is in every app.
  ///
  /// In the development app the Version row is also the way back out of showing the app as the
  /// public one: hold it for a second and the developer features return. A button for that sat
  /// in a section of its own, which was one more thing on the screen that the public app doesn't
  /// have — the point of the preview being to see the screen without those. The public app never
  /// compiles the gesture.
  private var aboutSection: some View {
    Section("About") {
      link("Manifesto", systemImage: "text.quote", to: AppLinks.manifesto)
      link("Terms & Conditions", systemImage: "doc.text", to: AppLinks.terms)
      link("Privacy Policy", systemImage: "hand.raised", to: AppLinks.privacy)
      link("Licenses", systemImage: "checkmark.seal", to: AppLinks.licenses)
      versionRow
    }
  }

  private var versionRow: some View {
    LabeledContent {
      Text(AppFlavor.version)
    } label: {
      Label("Version", systemImage: "info.circle")
    }
    #if ANVIL_DEV
      .contentShape(Rectangle())
      .onLongPressGesture(minimumDuration: 1) {
        guard settings.previewAsPublic else { return }
        settings.previewAsPublic = false
        settings.save()
      }
    #endif
  }

  /// A row that opens a page in Safari. In ink like the rows around it rather than the tint a
  /// link takes on its own: leaving the app is not a bigger thing than any other row does. The
  /// symbol in front is the row's, in the same ink, as Export chats has its own.
  private func link(_ title: String, systemImage: String, to url: URL) -> some View {
    link(to: url) { Label(title, systemImage: systemImage) }
  }

  /// The same row with a mark of our own in front — Discord's, X's or Instagram's, from the
  /// catalog — drawn as a template so it takes the row's ink the way a symbol does. A shade
  /// larger than a symbol: these marks carry their whitespace inside their box, so at a symbol's
  /// size they read smaller than the symbols in the rows around them.
  private func link(_ title: String, image: String, to url: URL) -> some View {
    link(to: url) {
      Label {
        Text(title)
      } icon: {
        Image(image)
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(width: Self.markSize, height: Self.markSize)
      }
    }
  }

  /// The side of the box a community mark is drawn in.
  private static let markSize: CGFloat = 24

  private func link<L: View>(to url: URL, @ViewBuilder label: () -> L) -> some View {
    Link(destination: url) {
      HStack {
        label()
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

/// A model on its way: the name, how far, a bar, and Cancel. Kept out of `SettingsScreen`'s
/// body on purpose — see `DownloadProgressBanner` in the chat for why — so that what the bar's
/// movement rebuilds is this row.
private struct DownloadingRow: View {
  @Environment(\.theme) private var theme
  let plan: ModelPlan
  var title: String? = nil
  let library: ModelLibrary
  let downloader: ModelDownloader

  var body: some View {
    let fraction = library.progress(of: plan)?.fraction ?? downloader.fraction
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title ?? plan.name)
        Spacer()
        Text("\(Int(fraction * 100))%")
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      ProgressView(value: fraction)
        .tint(theme.sendFill)
      // Only the moments the bar can't show: a part being checked, an archive being unpacked.
      if let note = library.stage(of: plan)?.note {
        Text(note)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Button("Cancel", role: .destructive) { Task { await library.cancelInstall(plan) } }
        .font(.subheadline)
        // Said outright: a button left to the default style inside a Form row hands its taps to
        // the row, which has nothing to do with them, and the press goes nowhere.
        .buttonStyle(.borderless)
    }
  }
}
