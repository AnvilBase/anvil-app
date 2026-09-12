import SwiftUI

/// The chat itself: the drawer of saved chats behind it, the bar across the top, the conversation,
/// and the composer under it.
struct ChatScreen: View {
  @Bindable var chat: ChatModel
  let model: ModelFile
  let onRemoveModel: () -> Void

  @State private var isSidebarOpen = false
  @State private var showingSettings = false
  @State private var showingDeveloper = false
  @State private var statsMessage: ChatMessage?
  /// The message open in the Select Text sheet.
  @State private var textToSelect: ChatMessage?
  /// The photo shown full screen after a tap.
  @State private var fullScreenPhoto: FullScreenPhoto?
  /// False once you scroll up, so a streaming reply doesn't drag you back down.
  @State private var isFollowingLatest = true
  @State private var isUserScrolling = false
  @FocusState private var inputFocused: Bool

  private let bottomID = "bottom"

  /// Whether to show what only the development app has. False in the public app always, and false
  /// in the development app while it is being looked at as the public one.
  private var showsDevelopmentFeatures: Bool {
    AppFlavor.showsDevelopmentFeatures(chat.settings.values)
  }

  var body: some View {
    SidebarContainer(isOpen: $isSidebarOpen) {
      ChatSidebar(
        chat: chat,
        onOpenChat: { closeSidebar() },
        onNewChat: {
          chat.newChat()
          closeSidebar()
        },
        onOpenSettings: {
          closeSidebar()
          showingSettings = true
        })
    } content: {
      GeometryReader { proxy in
        // The drawer runs the chat to the screen's edges, which leaves everything inside it a safe
        // area of nothing, so what is missing is put back here. There is no `NavigationStack` doing
        // it any more: the stack was only ever here for a toolbar, and a navigation bar that has
        // been hidden is still a navigation bar — it goes on taking every touch over the top of the
        // screen, which is where these buttons now are, and none of them could be pressed.
        let missing = WindowInsets.missing(from: proxy.safeAreaInsets)
        content
          // The colour runs to the screen edges; the content itself stays inside the safe area.
          .background(ChatStyle.page.ignoresSafeArea())
          .safeAreaInset(edge: .top, spacing: 0) { topBar.padding(.top, missing.top) }
          // The composer adds itself below this, so it clears the home indicator without the
          // keyboard, and sits straight on the keyboard when there is one.
          .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: missing.bottom).allowsHitTesting(false)
          }
      }
    }
    .onChange(of: chat.messagesSent) {
      // Whatever sent it — the button, or dictation finishing on its own — the keyboard goes down
      // with the message. It rides its own curve, which starts on this same frame as the bubble
      // lifts and the conversation scrolls, so the three read as one thing happening.
      inputFocused = false
    }
    .onChange(of: isSidebarOpen) { _, isOpen in
      // However the drawer was opened — the button, or a swipe from the edge — the keyboard goes
      // away with it.
      if isOpen { inputFocused = false }
    }
    .task(id: model) { await chat.load(model) }
    .sheet(isPresented: $showingSettings, onDismiss: { Task { await chat.settingsDidClose() } }) {
      SettingsScreen(
        chat: chat, model: model, settings: chat.settings, onRemoveModel: onRemoveModel)
    }
    .sheet(isPresented: $showingDeveloper) {
      NavigationStack {
        DeveloperScreen(chat: chat)
          .navigationTitle("Developer")
          #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
          #endif
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showingDeveloper = false }
            }
          }
      }
    }
    .sheet(item: $statsMessage) { message in
      if let stats = message.stats {
        ReplyStatsSheet(stats: stats)
      }
    }
    #if canImport(UIKit)
      .sheet(item: $textToSelect) { message in
        MessageTextSheet(text: message.text)
      }
    #endif
    .fullScreenCover(item: $fullScreenPhoto) { photo in
      PhotoViewer(image: photo.image)
    }
    .alert("Something went wrong", isPresented: alertBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(chat.alertMessage ?? "")
    }
  }

  private func closeSidebar() {
    withAnimation(ChatStyle.sidebarMotion) { isSidebarOpen = false }
  }

  private var alertBinding: Binding<Bool> {
    Binding(
      get: { chat.alertMessage != nil },
      set: { if !$0 { chat.alertMessage = nil } })
  }

  // MARK: - The bar across the top

  /// Buttons only. Nothing names the model or the app up here: which model is loaded is a thing to
  /// go and look at, not a thing to read over every conversation.
  ///
  /// Not a toolbar. The system bar is a fixed 44pt tall and sizes its buttons to suit itself, so a
  /// button in it could be neither the size of the drawer's nor the same size as the one beside
  /// it — iOS 26 gathers adjacent items into one shared capsule, which is what ran Developer and
  /// New chat together. These are the same circles the rest of the app is built from, spaced
  /// apart, so every button in Anvil is one button and one size.
  private var topBar: some View {
    HStack(spacing: 10) {
      barButton("Chats", systemImage: "line.3.horizontal") {
        inputFocused = false
        withAnimation(ChatStyle.sidebarMotion) { isSidebarOpen = true }
      }
      Spacer(minLength: 0)
      // The one thing the development app has that the public app doesn't, sitting just left of
      // New chat — and gone while the development app is being shown as the public one.
      if showsDevelopmentFeatures {
        barButton("Developer", systemImage: "hammer") { showingDeveloper = true }
      }
      barButton(
        "New chat", systemImage: "square.and.pencil", disabled: chat.messages.isEmpty
      ) {
        chat.newChat()
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
  }

  private func barButton(
    _ title: String, systemImage: String, disabled: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: ChatStyle.controlGlyph, weight: .medium))
        .frame(width: ChatStyle.control, height: ChatStyle.control)
        .liquidGlass(in: Circle(), interactive: true)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .opacity(disabled ? 0.4 : 1)
    .disabled(disabled)
    .accessibilityLabel(title)
  }

  // MARK: - What fills the screen

  @ViewBuilder
  private var content: some View {
    switch chat.loadState {
    // Loading is not a screen of its own. The chat is there from the first frame and you can
    // start typing into it; the composer's send button is what waits for the engine, and it
    // comes alive on its own the moment the model is ready.
    case .idle, .loading, .ready:
      conversation

    case .failed:
      failure
    }
  }

  /// The mark and the sentence, and nothing else. What to do about it lives in Settings › Model,
  /// which the bar across the top can still reach from here.
  ///
  /// The composer stays, because the screen is still the chat and taking it away would say the app
  /// had become something else. It simply won't send: Send is behind `canSend`, which wants a model
  /// that loaded, and the microphone wants the same.
  private var failure: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundStyle(.orange)
      Text("Couldn't load the model")
        .font(.title3.weight(.semibold))
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
  }

  private var conversation: some View {
    VStack(spacing: 0) {
      notices
      if chat.messages.isEmpty {
        emptyState
      } else {
        messageList
      }
    }
    // The first message of a chat doesn't slide into a list, it replaces the empty screen; this
    // is what keeps that swap from being a cut.
    .animation(ChatStyle.sendMotion, value: chat.messages.isEmpty)
    .sensoryFeedback(.impact(weight: .light), trigger: chat.replyStarted)
    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
  }

  private var composer: some View {
    Composer(
      chat: chat,
      isInputFocused: $inputFocused,
      onShowPhoto: { fullScreenPhoto = FullScreenPhoto(image: $0) })
  }

  @ViewBuilder
  private var notices: some View {
    ForEach([chat.notice, chat.chatNotice].compactMap { $0 }, id: \.self) { notice in
      Label(notice, systemImage: "exclamationmark.circle")
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
  }

  /// What you see before you've said anything: nothing at all. It is still a scroll view, though
  /// there is nothing to scroll, so that dragging down here puts the keyboard away exactly as it
  /// does over a conversation.
  private var emptyState: some View {
    GeometryReader { proxy in
      ScrollView {
        Color.clear.frame(height: proxy.size.height)
      }
      .scrollBounceBehavior(.always)
      .scrollDismissesKeyboard(.interactively)
    }
  }

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 22) {
          ForEach(chat.messages) { message in
            MessageRow(
              message: message,
              image: chat.images[message.id],
              isStreaming: chat.isGenerating && message.id == chat.messages.last?.id,
              isReplacedByEdit: chat.isReplacedByEdit(message.id),
              canEdit: !chat.isGenerating,
              canRegenerate: chat.canRegenerate(message.id),
              showsMetrics: showsDevelopmentFeatures,
              onEdit: {
                chat.beginEditing(message.id)
                inputFocused = true
              },
              onRegenerate: { chat.regenerate(message.id) },
              onSelectText: { textToSelect = message },
              onShowStats: { statsMessage = message },
              onShowImage: {
                if let image = chat.images[message.id] {
                  fullScreenPhoto = FullScreenPhoto(image: image)
                }
              }
            )
            .id(message.id)
            // Yours rises out of the capsule; the reply it is waiting on just appears.
            .transition(message.role == .user ? .sendLift : .opacity)
          }
          Color.clear
            .frame(height: 1)
            .id(bottomID)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        // Room to read the last line against, rather than having it end on the composer's glass.
        .padding(.bottom, 16)
        // Keyed on the count of messages sent rather than on the transcript itself: opening
        // another chat and streaming a reply both change the rows, and neither is an arrival.
        .animation(ChatStyle.sendMotion, value: chat.messagesSent)
      }
      .scrollDismissesKeyboard(.interactively)
      .overlay(alignment: .top) { Self.scrollFade(.top) }
      .overlay(alignment: .bottom) { Self.scrollFade(.bottom) }
      .modifier(LatestMessageTracker(isFollowing: $isFollowingLatest, isUserScrolling: $isUserScrolling))
      .onChange(of: chat.messages.count) { oldCount, newCount in
        // Sending jumps to your message and then follows the reply.
        if newCount > oldCount { jumpToLatest(proxy) }
      }
      .onChange(of: chat.openChat.id) { jumpToLatest(proxy) }
      .onChange(of: replyProgress) {
        if LatestMessageTracker.isSupported, isFollowingLatest, !isUserScrolling {
          proxy.scrollTo(bottomID, anchor: .bottom)
        }
      }
      .overlay(alignment: .bottom) {
        if LatestMessageTracker.isSupported, !isFollowingLatest, !chat.messages.isEmpty {
          Button {
            jumpToLatest(proxy)
          } label: {
            Image(systemName: "chevron.down")
              .font(.system(size: ChatStyle.inlineControlGlyph, weight: .medium))
              .foregroundStyle(.primary)
              .frame(width: ChatStyle.inlineControl, height: ChatStyle.inlineControl)
              .liquidGlass(in: Circle(), interactive: true)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Scroll to latest message")
          .padding(.bottom, 10)
          .transition(.scale.combined(with: .opacity))
        }
      }
      .animation(.snappy(duration: 0.2), value: isFollowingLatest)
    }
  }

  /// Changes whenever the last message grows, including its thinking and search activity.
  /// How far along the reply at the bottom is. The conversation follows this while it climbs, so
  /// anything that makes the last row taller has to be counted in it.
  ///
  /// Finishing is one of those things, and it is the one that was missed: the actions under a reply
  /// — copy, regenerate, the timings — appear only once there is nothing left to stream, and by
  /// then the text has stopped growing and this had stopped changing. The conversation stayed where
  /// the last word left it and the row that had just appeared sat behind the composer. So the end
  /// of the reply counts as a step of its own.
  /// The conversation thinning out at the very edges of the screen, rather than being cut off at a
  /// line.
  ///
  /// The page's own colour laid over the last few points, and not a mask, which is what this was.
  /// A mask puts the whole conversation into a layer of its own, and glass has nothing to refract
  /// once its backdrop is off in a layer somewhere — the buttons went from sitting over the words
  /// to sitting on nothing. Painted over the top instead, the words are still really there behind
  /// the glass, which is the only reason the glass is worth having.
  ///
  /// iOS 26 would do this itself, but only where a scroll view meets a real bar with a background
  /// to fade into, and the bar here is buttons on nothing.
  private static func scrollFade(_ edge: VerticalEdge) -> some View {
    LinearGradient(
      colors: [ChatStyle.page, ChatStyle.page.opacity(0)],
      startPoint: edge == .top ? .top : .bottom,
      endPoint: edge == .top ? .bottom : .top
    )
    .frame(height: 26)
    .allowsHitTesting(false)
  }

  private var replyProgress: Int {
    guard let last = chat.messages.last else { return 0 }
    return last.text.count + last.thinking.count + (last.searchQueries?.count ?? 0)
      + (last.sources?.count ?? 0) + (chat.isGenerating ? 0 : 1)
  }

  private func jumpToLatest(_ proxy: ScrollViewProxy) {
    isFollowingLatest = true
    // The same spring the message itself is riding, so the conversation comes up to meet it.
    withAnimation(ChatStyle.sendMotion) { proxy.scrollTo(bottomID, anchor: .bottom) }
  }
}

/// The message you just sent, arriving from the capsule you typed it in: a little lower, a little
/// smaller, and on its way up to where it belongs. Anchored bottom-trailing, the corner nearest the
/// composer it came out of.
///
/// Not a matched-geometry morph out of the field itself: the transcript is a lazy stack inside a
/// scroll view that is scrolling at the same moment, and a hero animation across that boundary is
/// a well-known way to get a bubble that lands in the wrong place.
private struct SendLift: ViewModifier {
  let lifting: Bool

  func body(content: Content) -> some View {
    content
      .opacity(lifting ? 0 : 1)
      .scaleEffect(lifting ? 0.94 : 1, anchor: .bottomTrailing)
      .offset(y: lifting ? 44 : 0)
  }
}

extension AnyTransition {
  fileprivate static var sendLift: AnyTransition {
    .asymmetric(
      insertion: .modifier(active: SendLift(lifting: true), identity: SendLift(lifting: false)),
      removal: .opacity)
  }
}

/// A photo to show full screen. Identifiable so each tap presents a fresh viewer.
private struct FullScreenPhoto: Identifiable {
  let id = UUID()
  let image: CGImage
}

/// Tracks whether you're at the bottom of the chat. Only your own scrolling changes this; content
/// growing while a reply streams doesn't. On iOS 17, which has no scroll-phase API, streaming
/// replies don't auto-scroll at all.
private struct LatestMessageTracker: ViewModifier {
  @Binding var isFollowing: Bool
  @Binding var isUserScrolling: Bool

  static var isSupported: Bool {
    if #available(iOS 18.0, *) { return true }
    return false
  }

  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      content
        .onScrollPhaseChange { _, phase, context in
          isUserScrolling = phase != .idle
          if phase == .idle { isFollowing = Self.isNearBottom(context.geometry) }
        }
        .onScrollGeometryChange(for: Bool.self, of: Self.isNearBottom) { _, nearBottom in
          if isUserScrolling { isFollowing = nearBottom }
        }
    } else {
      content
    }
  }

  @available(iOS 18.0, *)
  private static func isNearBottom(_ geometry: ScrollGeometry) -> Bool {
    geometry.visibleRect.maxY >= geometry.contentSize.height - 60
  }
}
