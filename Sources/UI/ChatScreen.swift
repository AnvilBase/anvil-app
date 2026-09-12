import SwiftUI

/// The chat itself: the drawer of saved chats behind it, the bar across the top, the conversation,
/// and the composer under it.
struct ChatScreen: View {
  @Bindable var chat: ChatModel
  let model: ModelFile
  let onRemoveModel: () -> Void

  @State private var isSidebarOpen = false
  @State private var showingSettings = false
  @State private var showingMetrics = false
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
      NavigationStack {
        content
          // The colour runs to the screen edges; the content itself stays inside the safe area.
          .background(ChatStyle.page.ignoresSafeArea())
          .toolbar { toolbarItems }
          #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
          #endif
      }
    }
    .task(id: model) { await chat.load(model) }
    .sheet(isPresented: $showingSettings, onDismiss: { Task { await chat.settingsDidClose() } }) {
      SettingsScreen(chat: chat, settings: chat.settings)
    }
    .sheet(isPresented: $showingMetrics) {
      NavigationStack {
        MetricsScreen(chat: chat)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showingMetrics = false }
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
    withAnimation(.interpolatingSpring(duration: 0.34, bounce: 0.08)) { isSidebarOpen = false }
  }

  private var alertBinding: Binding<Bool> {
    Binding(
      get: { chat.alertMessage != nil },
      set: { if !$0 { chat.alertMessage = nil } })
  }

  // MARK: - The bar across the top

  @ToolbarContentBuilder
  private var toolbarItems: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Button("Chats", systemImage: "sidebar.left") {
        inputFocused = false
        withAnimation(.interpolatingSpring(duration: 0.34, bounce: 0.08)) { isSidebarOpen = true }
      }
    }
    ToolbarItem(placement: .principal) {
      modelMenu
    }
    ToolbarItem(placement: .primaryAction) {
      Button("New chat", systemImage: "square.and.pencil") { chat.newChat() }
        .disabled(chat.messages.isEmpty)
    }
  }

  /// The name in the middle of the bar. Tapping it opens everything about how the app is behaving
  /// right now.
  private var modelMenu: some View {
    Menu {
      Section {
        Button("Performance", systemImage: "speedometer") { showingMetrics = true }
        Button("Settings", systemImage: "gearshape") { showingSettings = true }
      }
    } label: {
      HStack(spacing: 5) {
        Text(model.displayName)
          .font(.system(size: 17, weight: .semibold))
          .lineLimit(1)
        if AppFlavor.isDevelopment {
          Text("DEV")
            .font(.system(size: 10, weight: .heavy))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
        }
        Image(systemName: "chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .foregroundStyle(.primary)
      .contentShape(Rectangle())
    }
    .accessibilityLabel(model.displayName)
    .accessibilityHint("Opens performance and settings")
  }

  // MARK: - What fills the screen

  @ViewBuilder
  private var content: some View {
    switch chat.loadState {
    case .idle, .loading:
      VStack(spacing: 16) {
        ProgressView()
        Text("Loading \(model.displayName)…")
          .font(.headline)
        Text(
          "The first load can take a while as the engine prepares the model. Later launches are "
            + "much faster."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .failed(let message):
      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle")
          .font(.largeTitle)
          .foregroundStyle(.orange)
        Text("Couldn't load the model")
          .font(.headline)
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("Try again") {
          Task { await chat.load(model, force: true) }
        }
        .buttonStyle(.borderedProminent)
        Button("Settings") { showingSettings = true }
        Button("Remove model and re-import", role: .destructive, action: onRemoveModel)
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .ready:
      conversation
    }
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
    .safeAreaInset(edge: .bottom, spacing: 0) {
      Composer(
        chat: chat,
        isInputFocused: $inputFocused,
        onShowPhoto: { fullScreenPhoto = FullScreenPhoto(image: $0) })
    }
  }

  @ViewBuilder
  private var notices: some View {
    ForEach([chat.notice, chat.chatNotice].compactMap { $0 }, id: \.self) { notice in
      Label(notice, systemImage: "exclamationmark.circle")
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
  }

  /// What you see before you've said anything.
  private var emptyState: some View {
    VStack(spacing: 12) {
      Spacer()
      Image(systemName: "hammer.fill")
        .font(.system(size: 26, weight: .medium))
        .foregroundStyle(ChatStyle.sendGlyph)
        .frame(width: 56, height: 56)
        .background(ChatStyle.sendFill, in: Circle())
      Text("What's on your mind?")
        .font(.title2.weight(.semibold))
      Text(
        chat.webSearchOn
          ? "Answers are written on this iPhone. When the model searches, only its queries go to "
            + "Brave Search."
          : "Answers are written on this iPhone. Nothing you type leaves it."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 44)
      Spacer()
      // Sits a little above the middle, so it doesn't crowd the composer.
      Spacer().frame(height: 60)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
          }
          Color.clear
            .frame(height: 1)
            .id(bottomID)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
      }
      .scrollDismissesKeyboard(.interactively)
      .softScrollEdges()
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
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(.primary)
              .frame(width: 34, height: 34)
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
  private var replyProgress: Int {
    guard let last = chat.messages.last else { return 0 }
    return last.text.count + last.thinking.count + (last.searchQueries?.count ?? 0)
      + (last.sources?.count ?? 0)
  }

  private func jumpToLatest(_ proxy: ScrollViewProxy) {
    isFollowingLatest = true
    withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
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
