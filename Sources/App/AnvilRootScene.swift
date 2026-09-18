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

  /// One screen going and the next arriving. Short, and eased in rather than sprung: this is the
  /// app moving you on, not something you did being acknowledged.
  private static let screenChange: Animation = .easeIn(duration: 0.22)

  /// What the chat opens on: the model that is ready, or — once a model has ever been
  /// installed — a stand-in for the moment there isn't one, so that a download swapping
  /// Anvil Core for Anvil Pro or a subscription lapsing is the chat saying it can't load
  /// a model, with Settings a tap away. Choosing a model is the way in, and only that:
  /// this is nil, and that screen shows, only before there has ever been one.
  private var chatModel: ModelFile? {
    if case .ready(let model) = library.state { return model }
    // Two ways of knowing setup is behind us, because one of them once wasn't read back
    // from disk and the screen came back. The flag is what is remembered; a model on
    // the phone — usable or not — is what is true regardless of what was remembered.
    let setupIsDone = chat.settings.hasFinishedModelSetup || library.hasTextModel
    return setupIsDone ? missingModel : nil
  }

  /// A model that isn't there, for the chat to open on when there is nothing to open on.
  /// The chat tries to load it, is told there is no such file, and shows that; nothing is
  /// invented about what it would have been.
  private var missingModel: ModelFile? {
    guard let directory = try? ModelFiles.modelsDirectory() else { return nil }
    return ModelFile(
      url: directory.appendingPathComponent("none.\(ModelFiles.fileExtension)"),
      fileSize: 0,
      modificationDate: .distantPast,
      displayName: "No model",
      catalogID: nil,
      version: nil)
  }

  /// The theme the settings ask for, if Pro says so; Ink otherwise. Decided here, once, so a lapsed
  /// subscription falls back everywhere at the same moment and nothing downstream has to ask.
  private var theme: AppTheme {
    pro.isUnlocked ? chat.settings.theme : .ink
  }

  var body: some View {
    Group {
      if !chat.settings.hasSeenWelcome {
        WelcomeScreen {
          // Written down straight away rather than on the next save: whatever happens after this,
          // the welcome has been seen and should not come back.
          withAnimation(Self.screenChange) { chat.settings.hasSeenWelcome = true }
          chat.settings.save()
        }
        .transition(.opacity)
      } else if let model = chatModel {
        // One branch for the chat, whatever model it has, so that the view keeps its
        // identity when the model changes under it. Anvil Core going at the start of a
        // Pro download leaves a moment with nothing loadable, and when that moment was
        // a branch of its own SwiftUI built a new chat for it — and took the Settings
        // sheet, and the progress bar someone was watching, down with the old one.
        // Same branch, same view: the sheet stays up and the bar keeps moving.
        ChatScreen(chat: chat, model: model, library: library)
          .transition(.opacity)
      } else {
        ModelSetupScreen(library: library)
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
      if chat.settings.appLockEnabled {
        lock.lock()
      }
      // Lets iOS hand over anything a background download finished while the app was closed.
      ModelDownloadSession.shared.activate()
      // And clears away an unpacking the app was closed in the middle of. Here, before any download
      // is resumed, so it can never be one that is under way.
      ModelDownloadFiles.discardAbandonedUnpacking()
      ModelDownloadFiles.discardLeftovers()
      await chat.restoreHistory()
      // A download the app was closed part-way through is not picked up here: the screens
      // offer to carry it on, and nothing comes down the wire that nobody pressed for.
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
    .preferredColorScheme(chat.settings.appearance.colorScheme)
    // The theme, for every view that draws the chat, and Pro and the lock for the few that ask.
    // Ink keeps the system tint for controls; a coloured theme tints them in its own hue.
    .environment(\.theme, theme.palette)
    .tint(theme.isFree ? nil : theme.palette.accent)
    .environment(pro)
    .environment(lock)
    // The paywall needs it: buying Pro starts Pro downloading, and the paywall is pushed from
    // four screens, only some of which hold the library themselves.
    .environment(library)
    // The library hears about Pro here, the one place the App Store's answer is read, so a Pro
    // model falls back the moment a subscription lapses, the same way the theme does.
    .onChange(of: pro.isUnlocked, initial: true) { _, unlocked in
      library.proUnlocked = unlocked
    }
    // The first model to finish is the end of setting one up, and there is no going back
    // to that screen afterwards.
    .onChange(of: library.state, initial: true) { _, state in
      guard case .ready = state, !chat.settings.hasFinishedModelSetup else { return }
      chat.settings.hasFinishedModelSetup = true
      chat.settings.save()
    }
    // And the signed transaction that proves it to anvilai.com, which won't serve a
    // Pro model without one. Same place, for the same reason: the App Store's answer
    // is read once, here, and everything downstream is told.
    .onChange(of: pro.subscriptionProof, initial: true) { _, proof in
      ModelDownloader.subscriptionProof = proof
    }
    .onChange(of: chat.settings.appIcon) { _, icon in
      icon.apply()
    }
    // A sheet is its own presentation, which `preferredColorScheme` on the root does not reach:
    // Settings stayed as it was while the chat behind it changed, and caught up only when reopened.
    // The window is told as well, and so is every presentation up in it, at once.
    .onChange(of: chat.settings.appearance, initial: true) { _, appearance in
      appearance.applyToWindows()
    }
    .onChange(of: scenePhase) { _, phase in
      guard chat.settings.appLockEnabled || phase == .active else { return }
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
          // Coming back is the moment worth trying a model that wouldn't load again: whatever was
          // holding the memory it needed — another app, a picture being made — has had the time
          // away to let go of it.
          await chat.reloadIfNeeded()
        }
      @unknown default:
        break
      }
    }
  }
}

extension AppearancePreference {
  /// Sets the interface style on every window the app has and on every sheet, alert and dialog up
  /// in them. Unspecified for `system`, which hands the choice back to the phone.
  func applyToWindows() {
    #if canImport(UIKit)
      let style: UIUserInterfaceStyle =
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
      for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        for window in scene.windows {
          window.overrideUserInterfaceStyle = style
          // A sheet already up keeps the style it was presented with, which outranks the window's:
          // Settings, and the passcode sheet over it, have to be told themselves.
          var presented = window.rootViewController?.presentedViewController
          while let controller = presented {
            controller.overrideUserInterfaceStyle = style
            presented = controller.presentedViewController
          }
        }
      }
    #endif
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
