import SwiftUI

/// What this build actually is and what the model can call, for when the two apps start to differ.
///
/// Reachable from the hammer in the top bar of the development app only. It reads from `AppFlavor` and `ToolRegistry`
/// rather than from a hard-coded list, so a tool added to the registry shows up here on its own.
struct DeveloperScreen: View {
  let chat: ChatModel

  @Environment(\.dismiss) private var dismiss
  @Environment(ProAccess.self) private var pro

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
        LabeledContent("Brave Search key", value: AppSecrets.hasBraveSearchKey ? "Present" : "None")
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
          chat.settings.values.previewAsPublic = true
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
    }
    .navigationTitle("Developer")
  }

  /// Only the parts of the conversation options that decide whether a tool is available.
  private var options: ConversationOptions {
    ConversationOptions(
      systemPrompt: "",
      sampler: nil,
      thinking: false,
      webSearch: chat.webSearchOn,
      memoryEnabled: chat.settings.values.memoryEnabled,
      memories: [],
      imageGeneration: chat.canGenerateImages)
  }

}
