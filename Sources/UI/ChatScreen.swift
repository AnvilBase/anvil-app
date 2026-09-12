import SwiftUI

/// The chat itself: the message list, what sits above it (notices) and below it (the composer), and
/// everything the toolbar opens.
struct ChatScreen: View {
  @Bindable var chat: ChatModel
  let model: ModelFile
  let onRemoveModel: () -> Void

  @State private var showingChats = false
  @State private var showingSettings = false
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
    NavigationStack {
      content
        .navigationTitle(chat.openChat.displayTitle)
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .navigation) {
            Button("Chats", systemImage: "list.bullet") { showingChats = true }
          }
          ToolbarItemGroup(placement: .primaryAction) {
            if AppFlavor.isDevelopment {
              Text("DEV")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Development build")
            }
            ComputerStatusBadge(chat: chat)
            LiveCPUBadge(chat: chat)
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
            Button("New chat", systemImage: "square.and.pencil") { chat.newChat() }
              .disabled(chat.messages.isEmpty)
          }
        }
    }
    .task(id: model) { await chat.load(model) }
    .sheet(isPresented: $showingChats) {
      ChatListScreen(chat: chat)
    }
    .sheet(isPresented: $showingSettings, onDismiss: { Task { await chat.settingsDidClose() } }) {
      SettingsScreen(chat: chat, settings: chat.settings)
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

  private var alertBinding: Binding<Bool> {
    Binding(
      get: { chat.alertMessage != nil },
      set: { if !$0 { chat.alertMessage = nil } })
  }

  @ViewBuilder
  private var content: some View {
    switch chat.loadState {
    case .idle, .loading:
      VStack(spacing: 16) {
        ProgressView()
        Text("Loading \(model.url.lastPathComponent)…")
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

    case .ready:
      conversation
    }
  }

  private var conversation: some View {
    VStack(spacing: 0) {
      ForEach([chat.notice, chat.chatNotice].compactMap { $0 }, id: \.self) { notice in
        Text(notice)
          .font(.footnote)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
          .padding(.vertical, 8)
          .background(Color.yellow.opacity(0.2))
      }
      messageList
      Divider()
      Composer(
        chat: chat,
        isInputFocused: $inputFocused,
        onShowPhoto: { fullScreenPhoto = FullScreenPhoto(image: $0) },
        onOpenSettings: { showingSettings = true })
    }
  }

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 12) {
          if chat.messages.isEmpty {
            Text(
              chat.webSearchOn
                ? "Web search is on: when the model searches, its queries go to Brave Search. "
                  + "Everything else stays on this iPhone."
                : "Everything runs on this iPhone. Nothing is sent over the network."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 40)
          }
          ForEach(chat.messages) { message in
            MessageBubble(
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
        .padding()
      }
      .scrollDismissesKeyboard(.interactively)
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
      .overlay(alignment: .bottomTrailing) {
        if LatestMessageTracker.isSupported, !isFollowingLatest, !chat.messages.isEmpty {
          Button {
            jumpToLatest(proxy)
          } label: {
            Image(systemName: "arrow.down.circle.fill")
              .font(.largeTitle)
              .symbolRenderingMode(.hierarchical)
          }
          .accessibilityLabel("Scroll to latest message")
          .padding()
        }
      }
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
