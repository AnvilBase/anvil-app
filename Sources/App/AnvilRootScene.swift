import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// The whole app, shared by both targets. `Apps/AnvilAI` and `Apps/AnvilAIDev` each declare an
/// `@main` App that shows nothing but this scene.
struct AnvilRootScene: Scene {
  @State private var pro: ProAccess
  @State private var lock = AppLock()
  @State private var library = ModelLibrary()
  @State private var chat: ChatModel

  init() {
    // The chat needs to know about Pro, so the two are made together.
    let pro = ProAccess()
    _pro = State(initialValue: pro)
    _chat = State(initialValue: ChatModel(settings: SettingsStore(), pro: pro))

    #if canImport(UIKit)
      // No scroll bars anywhere, at the level below SwiftUI. `.scrollIndicators(.hidden)` on the
      // root view (below) covers every SwiftUI scroll view, list and form; this covers what that
      // can't reach — the UIKit text views behind a multi-line field and the text sheet, and any
      // UIScrollView SwiftUI makes on its own behalf.
      UIScrollView.appearance().showsVerticalScrollIndicator = false
      UIScrollView.appearance().showsHorizontalScrollIndicator = false
    #endif
  }

  var body: some Scene {
    WindowGroup {
      RootView(library: library, chat: chat, pro: pro, lock: lock)
    }
    // Takes delivery of model parts that finished downloading while the app wasn't running.
    .backgroundTask(.urlSession(ModelDownloadSession.identifier)) {
      await ModelDownloadSession.shared.handleBackgroundEvents()
    }
  }
}

/// Switches between welcoming you, installing a model and chatting with it, and handles the work
/// that belongs to the app as a whole rather than to one screen: restoring history, picking up a
/// download that finished in the background, deleting expired chats, the theme, the lock.
private struct RootView: View {
  let library: ModelLibrary
  let chat: ChatModel
  let pro: ProAccess
  let lock: AppLock

  @Environment(\.scenePhase) private var scenePhase

  #if ANVIL_DEV
    /// The development app can go into the chat without a model, to look at the screens without
    /// waiting on gigabytes. The chat opens on "Couldn't load the model" and its composer won't send,
    /// which is the honest state of things; the moment a model is installed it takes over. Not
    /// written down: skipping is for this run, and the next launch asks again.
    @State private var skippedModelSetup = false
  #endif

  /// One screen going and the next arriving. Short, and eased in rather than sprung: this is the
  /// app moving you on, not something you did being acknowledged.
  private static let screenChange: Animation = .easeIn(duration: 0.22)

  /// The theme the settings ask for, if Pro says so; Ink otherwise. Decided here, once, so a lapsed
  /// subscription falls back everywhere at the same moment and nothing downstream has to ask.
  private var theme: AppTheme {
    pro.isUnlocked ? chat.settings.values.theme : .ink
  }

  /// Skip on the model screen, in the development app only. nil — no button — everywhere else,
  /// including the development app when it is showing itself as the public one.
  private var skipModelSetup: (() -> Void)? {
    #if ANVIL_DEV
      guard AppFlavor.showsDevelopmentFeatures(chat.settings.values) else { return nil }
      return { withAnimation(Self.screenChange) { skippedModelSetup = true } }
    #else
      return nil
    #endif
  }

  /// A model that isn't there, for the chat to open on after Skip. The chat tries to load it, is
  /// told there is no such file, and shows that; nothing is invented about what it would have been.
  private var skippedModel: ModelFile? {
    #if ANVIL_DEV
      guard skippedModelSetup, let directory = try? ModelFiles.modelsDirectory() else { return nil }
      return ModelFile(
        url: directory.appendingPathComponent("none.\(ModelFiles.fileExtension)"),
        fileSize: 0,
        modificationDate: .distantPast,
        displayName: "No model",
        catalogID: nil,
        version: nil)
    #else
      return nil
    #endif
  }

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
        ChatScreen(chat: chat, model: model, library: library)
          .transition(.opacity)
      } else if let placeholder = skippedModel {
        ChatScreen(chat: chat, model: placeholder, library: library)
          .transition(.opacity)
      } else {
        ModelSetupScreen(library: library, onSkip: skipModelSetup)
          .transition(.opacity)
      }
    }
    // Over everything, and only while locked. What it covers is this view; the sheets a screen may
    // have up are closed by that screen when the lock comes down — see `ChatScreen`.
    .overlay {
      if lock.isShowing {
        LockScreen(lock: lock)
          .transition(.opacity)
      }
    }
    .animation(Self.screenChange, value: lock.isShowing)
    .task {
      // Locked from the first frame if that is what was asked for, before anything is drawn under
      // it that shouldn't be seen.
      // Nothing happens without a passcode to lock behind: `lock()` sees to that.
      if chat.settings.values.appLockEnabled {
        lock.lock()
      }
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
    // The theme, for every view that draws the chat, and Pro and the lock for the few that ask.
    // Ink keeps the system tint for controls; a coloured theme tints them in its own hue.
    .environment(\.theme, theme.palette)
    .tint(theme.isFree ? nil : theme.palette.accent)
    .environment(pro)
    .environment(lock)
    // The library hears about Pro here, the one place the App Store's answer is read, so a Pro
    // model falls back the moment a subscription lapses, the same way the theme does.
    .onChange(of: pro.isUnlocked, initial: true) { _, unlocked in
      library.proUnlocked = unlocked
    }
    .onChange(of: chat.settings.values.appIcon) { _, icon in
      icon.apply()
    }
    .onChange(of: scenePhase) { _, phase in
      guard chat.settings.values.appLockEnabled || phase == .active else { return }
      switch phase {
      case .inactive:
        // Control Centre, a notification pulled down, the app switcher: the screen is covered so
        // the snapshot iOS takes shows the mark and not the chat, but nothing is owed to get back.
        lock.cover()
      case .background:
        // Leaving is what locks it.
        lock.lock()
      case .active:
        lock.uncover()
        Task {
          await library.refresh()
          await chat.purgeExpiredChats()
        }
      @unknown default:
        break
      }
    }
  }
}

extension AppIconChoice {
  /// Asks iOS for this icon. iOS puts up its own "You have changed the icon" alert, which is the
  /// system's confirmation and not something to duplicate.
  func apply() {
    #if canImport(UIKit)
      guard UIApplication.shared.supportsAlternateIcons,
        UIApplication.shared.alternateIconName != alternateIconName
      else { return }
      UIApplication.shared.setAlternateIconName(alternateIconName)
    #endif
  }
}
