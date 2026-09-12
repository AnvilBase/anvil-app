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

/// Switches between welcoming you, installing a model and chatting with it, and handles the work
/// that belongs to the app as a whole rather than to one screen: restoring history, picking up a
/// download that finished in the background, and deleting expired chats.
private struct RootView: View {
  let library: ModelLibrary
  let chat: ChatModel

  @Environment(\.scenePhase) private var scenePhase

  /// One screen going and the next arriving. Short, and eased in rather than sprung: this is the
  /// app moving you on, not something you did being acknowledged.
  private static let screenChange: Animation = .easeIn(duration: 0.22)

  var body: some View {
    Group {
      if !chat.settings.values.hasSeenWelcome {
        WelcomeScreen {
          // Written down straight away rather than on the next save: whatever happens after this,
          // the welcome has been seen and should not come back.
          withAnimation(Self.screenChange) { chat.settings.values.hasSeenWelcome = true }
          chat.settings.save()
        }
        .transition(.opacity)
      } else if case .ready(let model) = library.state {
        ChatScreen(chat: chat, model: model) {
          Task {
            await chat.unload()
            await library.removeModel()
          }
        }
        .transition(.opacity)
      } else {
        ModelSetupScreen(library: library)
          .transition(.opacity)
      }
    }
    .task {
      // Lets iOS hand over anything a background download finished while the app was closed.
      ModelDownloadSession.shared.activate()
      await chat.restoreHistory()
      await library.refresh()
    }
    // Two steps up from the system default, everywhere, and the only place any text size is set:
    // everything else in the app asks for .body, .subheadline and the rest, so one number here
    // moves all of it together. A floor rather than a fixed size, so anyone who has already asked
    // iOS for larger text keeps the size they chose.
    .dynamicTypeSize(.xxLarge...)
    // No scroll bars anywhere, and the only place that is said: every scroll view, list and form in
    // the app inherits it. Nothing marks the edges of a page but the page itself — a bar sliding up
    // and down the side would be one more thing over the content to look at.
    .scrollIndicators(.hidden)
    // Nothing for "System", which leaves SwiftUI following the phone.
    .preferredColorScheme(chat.settings.values.appearance.colorScheme)
    .onChange(of: scenePhase) {
      guard scenePhase == .active else { return }
      Task {
        await library.refresh()
        await chat.purgeExpiredChats()
      }
    }
  }
}
