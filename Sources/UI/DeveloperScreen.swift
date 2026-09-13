import SwiftUI

/// What this build actually is and what the model can call, for when the two apps start to differ.
///
/// Reachable from the hammer in the top bar of the development app only. It reads from `AppFlavor` and `ToolRegistry`
/// rather than from a hard-coded list, so a tool added to the registry shows up here on its own.
struct DeveloperScreen: View {
  let chat: ChatModel
  let library: ModelLibrary

  @Environment(\.dismiss) private var dismiss
  @Environment(ProAccess.self) private var pro
  @State private var confirmingStartOver = false

  var body: some View {
    @Bindable var pro = pro
    List {
      #if ANVIL_DEV
        // Pro without buying it, for looking at the screens. Compiled into the development app
        // only, like the rest of this screen's reasons to exist; the public app has no such switch.
        Section("Anvil Pro") {
          Toggle("Preview Pro", isOn: $pro.previewUnlocked)
        }
      #endif

      Section {
        LabeledContent("Flavor", value: AppFlavor.current.rawValue)
        LabeledContent("App name", value: AppFlavor.appName)
        LabeledContent("Bundle identifier", value: AppFlavor.storageNamespace)
        LabeledContent("Version", value: AppFlavor.version)
        LabeledContent(
          "Web search",
          value: AppSecrets.hasBraveSearchKey ? "Brave directly, key in build" : "Through \(AnvilServer.host)")
      } header: {
        Text("Build")
      } footer: {
        Text(
          "The public and development apps install side by side and keep separate chats, settings, "
            + "and imported models.")
      }

      Section {
        ForEach(ToolRegistry.catalog) { entry in
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Text(entry.name)
                .font(.body.monospaced())
              if entry.isDevelopmentOnly {
                Text("DEV")
                  .font(.caption2.weight(.bold))
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1)
                  .background(.tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
              }
              Spacer()
              Text(ToolRegistry.isAvailable(entry, with: options) ? "Available now" : "Off")
                .font(.caption)
                .foregroundStyle(
                  ToolRegistry.isAvailable(entry, with: options) ? Color.green : .secondary)
            }
            Text(entry.summary)
              .font(.footnote)
              .foregroundStyle(.secondary)
            Text(entry.requirement.label)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 2)
        }
      } header: {
        Text("Tools")
      } footer: {
        Text(
          "Declared in Sources/Tools/ToolRegistry.swift. Entries inside its ANVIL_DEV block exist "
            + "only in this app; the public build never sees them.")
      }

      Section {
        NavigationLink("Performance and usage") { MetricsScreen(chat: chat) }
        NavigationLink("Reply history") { PerformanceHistory(chat: chat) }
      } header: {
        Text("Performance")
      } footer: {
        Text(
          "Live device readings and the running totals, and every measured reply plotted over "
            + "time. Both live here rather than in the app itself: they are for working on Anvil, "
            + "not for using it.")
      }

      Section("Network") {
        LabeledContent("Connection", value: chat.isOffline ? "Offline" : "Online")
      }

      Section {
        Button("Switch to the public build") {
          chat.settings.previewAsPublic = true
          chat.settings.save()
          dismiss()
        }
      } header: {
        Text("Presentation")
      } footer: {
        Text(
          "Takes away everything the public app doesn't have — this screen's hammer, the timings "
            + "under a reply, the metrics in Settings — so a change can be looked at the way it "
            + "will ship, without swapping apps. Nothing is uninstalled and nothing moves; "
            + "Settings has the way back.")
      }

      Section {
        Button("Delete everything and start over", role: .destructive) {
          confirmingStartOver = true
        }
      } header: {
        Text("Reset")
      } footer: {
        Text(
          "Deletes every model, chat and memory, the usage totals, the passcode and every setting, "
            + "and shows the welcome screen again: a fresh install, without reinstalling.")
      }
    }
    .navigationTitle("Developer")
    .confirmationDialog(
      "Delete everything and start over?", isPresented: $confirmingStartOver,
      titleVisibility: .visible
    ) {
      Button("Delete everything", role: .destructive) { resetApp() }
    } message: {
      Text("Models, chats, memories and settings all go. This can't be undone.")
    }
  }

  /// A fresh install without reinstalling. The engines let go of their files first, the way a
  /// swipe-to-delete in Settings does; then every model goes, every chat, every memory, the
  /// totals and the passcode; the settings go back to their defaults — the welcome flag with
  /// them, so the root shows the welcome screen and the install screen after it — and the Pro
  /// preview is back on, the way the development app opens.
  private func resetApp() {
    Task {
      await chat.unload()
      await chat.unloadImageModel()
      for file in library.installed {
        await library.remove(file)
      }
      chat.deleteAllChats()
      chat.memory.deleteAll()
      chat.resetTotals()
      AppLock.clearPasscode()
      #if ANVIL_DEV
        pro.previewUnlocked = true
      #endif
      chat.settings.values = AppSettings()
      chat.settings.save()
      dismiss()
    }
  }

  /// Only the parts of the conversation options that decide whether a tool is available.
  private var options: ConversationOptions {
    ConversationOptions(
      systemPrompt: "",
      sampler: nil,
      webSearch: chat.webSearchOn,
      memoryEnabled: chat.settings.memoryEnabled,
      memories: [],
      imageGeneration: chat.canGenerateImages)
  }

}
