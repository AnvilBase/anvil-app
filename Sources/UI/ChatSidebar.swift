import SwiftUI

/// The drawer behind the chat: search at the top, a new chat, then every saved chat newest first
/// under the day it was last used, and your account at the bottom.
struct ChatSidebar: View {
  let chat: ChatModel
  let onOpenChat: () -> Void
  let onNewChat: () -> Void
  let onOpenSettings: () -> Void

  @State private var query = ""

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
      searchField
      newChatRow
      chatList
      clearAllRow
      Divider()
        .overlay(ChatStyle.hairline)
      accountRow
    }
    .background(ChatStyle.sidebar)
  }

  // MARK: - Top

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.secondary)
      TextField("Search", text: $query)
        .textFieldStyle(.plain)
        .submitLabel(.search)
        .autocorrectionDisabled()
      if !query.isEmpty {
        Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
          .labelStyle(.iconOnly)
          .foregroundStyle(.secondary)
          .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .liquidGlass(in: Capsule())
    .padding(.horizontal, 14)
    .padding(.top, 8)
    .padding(.bottom, 12)
  }

  private var newChatRow: some View {
    Button(action: onNewChat) {
      Label("New chat", systemImage: "square.and.pencil")
        .font(.system(size: 16, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .padding(.horizontal, 14)
    .padding(.bottom, 4)
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
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.secondary)
              .textCase(nil)
          }
        }
      }
      .listStyle(.plain)
      .listSectionSpacing(.compact)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, 36)
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
          .font(.system(size: 16))
          .lineLimit(1)
        if let match = searchPreview(for: saved) {
          Text(match)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
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
        .font(.subheadline.weight(.semibold))
      Text(detail)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 28)
  }

  // MARK: - Bottom

  /// Clears every saved chat on one tap, with nothing to confirm — which is what was asked for, and
  /// worth knowing there is no undo behind it.
  private var clearAllRow: some View {
    Button {
      chat.deleteAllChats()
      onOpenChat()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "trash")
          .font(.system(size: 15, weight: .medium))
        Text("Clear All Chats")
          .font(.system(size: 15, weight: .medium))
        Spacer(minLength: 0)
      }
      .foregroundStyle(.red)
      .padding(.horizontal, 14)
      .frame(height: 44)
      .liquidGlass(in: Capsule(), interactive: true)
    }
    .buttonStyle(.plain)
    .disabled(chat.savedChats.isEmpty)
    .padding(.horizontal, 14)
    .padding(.bottom, 10)
    .accessibilityLabel("Clear All Chats")
  }

  private var accountRow: some View {
    Button(action: onOpenSettings) {
      HStack(spacing: 10) {
        Text(String(AppFlavor.appName.prefix(1)))
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(ChatStyle.sendGlyph)
          .frame(width: 30, height: 30)
          .background(ChatStyle.sendFill, in: Circle())
        VStack(alignment: .leading, spacing: 1) {
          Text(AppFlavor.appName)
            .font(.system(size: 15, weight: .medium))
          Text(AppFlavor.isDevelopment ? "Development build" : "On this iPhone")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "ellipsis")
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .accessibilityLabel("Settings")
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
