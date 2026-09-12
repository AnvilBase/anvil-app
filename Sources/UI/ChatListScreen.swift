import SwiftUI

/// Saved chats, newest first: search by title or message text, tap to open, swipe to delete.
struct ChatListScreen: View {
  let chat: ChatModel

  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespaces)
  }

  private var results: [Chat] {
    guard !trimmedQuery.isEmpty else { return chat.savedChats }
    return chat.savedChats.filter { saved in
      saved.title.localizedStandardContains(trimmedQuery)
        || saved.messages.contains { $0.text.localizedStandardContains(trimmedQuery) }
    }
  }

  var body: some View {
    NavigationStack {
      List {
        if chat.savedChats.isEmpty {
          ContentUnavailableView(
            "No saved chats", systemImage: "bubble.left.and.bubble.right",
            description: Text("Chats are saved on this iPhone as you send messages."))
        } else if results.isEmpty {
          ContentUnavailableView.search(text: trimmedQuery)
        }
        ForEach(results) { saved in
          Button {
            chat.open(saved.id)
            dismiss()
          } label: {
            row(for: saved)
          }
          .foregroundStyle(.primary)
        }
        .onDelete { offsets in
          let ids = offsets.map { results[$0].id }
          for id in ids { chat.deleteChat(id) }
        }
      }
      .searchable(text: $query, prompt: "Search chats")
      .navigationTitle("Chats")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("New chat", systemImage: "square.and.pencil") {
            chat.newChat()
            dismiss()
          }
        }
      }
    }
  }

  private func row(for saved: Chat) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(saved.displayTitle)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        if saved.id == chat.openChat.id {
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
            .accessibilityLabel("Open")
        }
      }
      if let preview = preview(for: saved) {
        Text(preview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Text(caption(for: saved))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  /// While searching, the text around the first match; otherwise the latest message.
  private func preview(for saved: Chat) -> String? {
    if !trimmedQuery.isEmpty,
      let match = saved.messages.first(where: { $0.text.localizedStandardContains(trimmedQuery) })
    {
      return snippet(of: match.text, around: trimmedQuery)
    }
    return saved.messages.last(where: { !$0.text.isEmpty })?.text
  }

  /// About 40 characters either side of the first match.
  private func snippet(of text: String, around term: String) -> String {
    guard let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
      return text
    }
    let start =
      text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
    let prefix = start > text.startIndex ? "…" : ""
    let suffix = end < text.endIndex ? "…" : ""
    return prefix + String(text[start..<end]) + suffix
  }

  private func caption(for saved: Chat) -> String {
    let updated = saved.updatedAt.formatted(.relative(presentation: .named))
    let days = chat.settings.values.historyRetentionDays
    guard days > 0 else { return "Updated \(updated)" }
    let expiry = saved.updatedAt.addingTimeInterval(Double(days) * 86_400)
    return "Updated \(updated) · deleted \(expiry.formatted(.relative(presentation: .named)))"
  }
}
