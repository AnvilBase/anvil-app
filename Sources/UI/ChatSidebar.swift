import SwiftUI

/// The drawer behind the chat: the name and settings across the top, every saved chat newest first
/// under the day it was last used, and the three things you can do to that list along the bottom.
struct ChatSidebar: View {
  let chat: ChatModel
  let onOpenChat: () -> Void
  let onNewChat: () -> Void
  let onOpenSettings: () -> Void

  @State private var query = ""
  /// Search replaces the row of buttons it was opened from, rather than sitting above them taking
  /// up room on a screen that is mostly a list.
  @State private var isSearching = false
  @State private var confirmingClearAll = false
  @FocusState private var searchFocused: Bool

  private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

  private var results: [Chat] {
    guard !trimmedQuery.isEmpty else { return chat.savedChats }
    return chat.savedChats.filter { saved in
      saved.title.localizedStandardContains(trimmedQuery)
        || saved.messages.contains { $0.text.localizedStandardContains(trimmedQuery) }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      chatList
      actionBar
    }
    .background(ChatStyle.sidebar)
    .confirmationDialog(
      "Are you sure?", isPresented: $confirmingClearAll, titleVisibility: .visible
    ) {
      Button("Clear All", role: .destructive) {
        chat.deleteAllChats()
        onOpenChat()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every chat saved on this iPhone is deleted. This can't be undone.")
    }
  }

  // MARK: - Top

  private var header: some View {
    HStack(spacing: 10) {
      // Drawn flat, not lit up a row at a time: the mark animating itself in every time the drawer
      // is pulled open would be the loudest thing on the screen.
      PixelAnvil(size: 24, animated: false)
      Text("Anvil")
        .font(.title2.weight(.semibold))
      Spacer(minLength: 0)
      Button(action: onOpenSettings) {
        Image(systemName: "gearshape")
          .font(.system(size: 20, weight: .medium))
          .frame(width: 44, height: 44)
          .liquidGlass(in: Circle(), interactive: true)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.primary)
      .accessibilityLabel("Settings")
    }
    .padding(.horizontal, 16)
    .padding(.top, 10)
    .padding(.bottom, 12)
  }

  // MARK: - Chats

  @ViewBuilder
  private var chatList: some View {
    if chat.savedChats.isEmpty {
      emptyState(
        "No chats yet",
        detail: "Chats are saved on this iPhone as you send messages.")
    } else if results.isEmpty {
      emptyState("No results", detail: "Nothing here matches “\(trimmedQuery)”.")
    } else {
      List {
        ForEach(ChatDateGroup.group(results), id: \.title) { group in
          Section {
            ForEach(group.chats) { saved in
              row(for: saved)
            }
          } header: {
            Text(group.title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.secondary)
              .textCase(nil)
          }
        }
      }
      .listStyle(.plain)
      .listSectionSpacing(.compact)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, 42)
    }
  }

  private func row(for saved: Chat) -> some View {
    let isOpen = saved.id == chat.openChat.id
    return Button {
      chat.open(saved.id)
      onOpenChat()
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(saved.displayTitle)
          .font(.body)
          .lineLimit(1)
        if let match = searchPreview(for: saved) {
          Text(match)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        isOpen ? ChatStyle.sidebarRowHighlight : .clear,
        in: RoundedRectangle(cornerRadius: 10)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 14))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .swipeActions(edge: .trailing) {
      Button("Delete", systemImage: "trash", role: .destructive) { chat.deleteChat(saved.id) }
    }
    .contextMenu {
      Button("Delete chat", systemImage: "trash", role: .destructive) {
        chat.deleteChat(saved.id)
      }
    }
    .accessibilityLabel(saved.displayTitle)
    .accessibilityValue(isOpen ? "Open" : "")
    .accessibilityHint(caption(for: saved))
  }

  private func emptyState(_ title: String, detail: String) -> some View {
    VStack(spacing: 6) {
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 28)
  }

  // MARK: - Bottom

  /// Clear the list, search it, or start a new chat — or, once search is open, the field itself in
  /// their place.
  @ViewBuilder
  private var actionBar: some View {
    Group {
      if isSearching {
        searchField
      } else {
        HStack(spacing: 10) {
          clearAllButton
          searchButton
          newChatButton
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 8)
    .padding(.bottom, 12)
  }

  /// The one named button of the three, because it's the one there is no undo for. It asks before
  /// it does anything.
  private var clearAllButton: some View {
    Button { confirmingClearAll = true } label: {
      Label("Clear All", systemImage: "trash")
        .font(.body.weight(.medium))
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .liquidGlass(in: Capsule(), interactive: true)
    }
    .buttonStyle(.plain)
    .disabled(chat.savedChats.isEmpty)
    .accessibilityLabel("Clear all chats")
  }

  private var searchButton: some View {
    Button {
      withAnimation(.snappy(duration: 0.22)) { isSearching = true }
      searchFocused = true
    } label: {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 20, weight: .medium))
        .frame(width: 52, height: 52)
        .liquidGlass(in: Circle(), interactive: true)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .disabled(chat.savedChats.isEmpty)
    .accessibilityLabel("Search chats")
  }

  private var newChatButton: some View {
    Button(action: onNewChat) {
      Image(systemName: "square.and.pencil")
        .font(.system(size: 20, weight: .medium))
        .frame(width: 52, height: 52)
        .liquidGlass(in: Circle(), interactive: true)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .accessibilityLabel("New chat")
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.body.weight(.semibold))
          .foregroundStyle(.secondary)
        TextField("Search", text: $query)
          .textFieldStyle(.plain)
          .font(.body)
          .submitLabel(.search)
          .autocorrectionDisabled()
          .focused($searchFocused)
      }
      .padding(.horizontal, 16)
      .frame(height: 52)
      .liquidGlass(in: Capsule())

      Button("Cancel") {
        query = ""
        searchFocused = false
        withAnimation(.snappy(duration: 0.22)) { isSearching = false }
      }
      .font(.body)
      .buttonStyle(.plain)
      .foregroundStyle(.primary)
    }
  }

  // MARK: - Text

  /// While searching, the line the match is on, so you can see why a chat came up.
  private func searchPreview(for saved: Chat) -> String? {
    guard !trimmedQuery.isEmpty,
      let match = saved.messages.first(where: { $0.text.localizedStandardContains(trimmedQuery) }),
      let range = match.text.range(
        of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive])
    else { return nil }
    let start =
      match.text.index(range.lowerBound, offsetBy: -30, limitedBy: match.text.startIndex)
      ?? match.text.startIndex
    let end =
      match.text.index(range.upperBound, offsetBy: 30, limitedBy: match.text.endIndex)
      ?? match.text.endIndex
    let prefix = start > match.text.startIndex ? "…" : ""
    let suffix = end < match.text.endIndex ? "…" : ""
    return prefix + String(match.text[start..<end]) + suffix
  }

  private func caption(for saved: Chat) -> String {
    let updated = saved.updatedAt.formatted(.relative(presentation: .named))
    let days = chat.settings.values.historyRetentionDays
    guard days > 0 else { return "Updated \(updated)" }
    let expiry = saved.updatedAt.addingTimeInterval(Double(days) * 86_400)
    return "Updated \(updated) · deleted \(expiry.formatted(.relative(presentation: .named)))"
  }
}

/// Chats under the heading for when they were last used: Today, Yesterday, the last week, the last
/// month, then by month.
struct ChatDateGroup {
  let title: String
  let chats: [Chat]

  static func group(_ chats: [Chat], now: Date = Date()) -> [ChatDateGroup] {
    var order: [String] = []
    var buckets: [String: [Chat]] = [:]
    for chat in chats {
      let title = heading(for: chat.updatedAt, now: now)
      if buckets[title] == nil { order.append(title) }
      buckets[title, default: []].append(chat)
    }
    return order.map { ChatDateGroup(title: $0, chats: buckets[$0] ?? []) }
  }

  private static func heading(for date: Date, now: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
    if days < 7 { return "Previous 7 days" }
    if days < 30 { return "Previous 30 days" }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return date.formatted(.dateTime.month(.wide))
    }
    return date.formatted(.dateTime.month(.wide).year())
  }
}
