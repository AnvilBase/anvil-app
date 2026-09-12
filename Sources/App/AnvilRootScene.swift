import SwiftUI

/// The whole app, shared by both targets. `Apps/AnvilAI` and `Apps/AnvilAIDev` each declare an
/// `@main` App that shows nothing but this scene.
struct AnvilRootScene: Scene {
  @State private var library = ModelLibrary()
  @State private var chat = ChatModel(settings: SettingsStore())

  var body: some Scene {
    WindowGroup {
      RootView(library: library, chat: chat)
    }
    // Takes delivery of model parts that finished downloading while the app wasn't running.
    .backgroundTask(.urlSession(ModelDownloadSession.identifier)) {
      await ModelDownloadSession.shared.handleBackgroundEvents()
    }
  }
}

/// Switches between importing a model and chatting with it, and handles the work that belongs to the
/// app as a whole rather than to one screen: restoring history, noticing a model copied in while the
/// app was in the background, and deleting expired chats.
private struct RootView: View {
  let library: ModelLibrary
  let chat: ChatModel

  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      if case .ready(let model) = library.state {
        ChatScreen(chat: chat, model: model) {
          Task {
            await chat.unload()
            await library.removeModel()
          }
        }
      } else {
        ModelSetupScreen(library: library)
      }
    }
    .task {
      // Lets iOS hand over anything a background download finished while the app was closed.
      ModelDownloadSession.shared.activate()
      await chat.restoreHistory()
      await library.refresh()
    }
    .onChange(of: scenePhase) {
      guard scenePhase == .active else { return }
      Task {
        await library.refresh()
        await chat.purgeExpiredChats()
      }
    }
  }
}
