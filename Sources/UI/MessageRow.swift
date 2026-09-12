import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// One message. What you send sits in a grey bubble on the right; the reply has no bubble at all
/// and runs the full width of the page, with everything the model did along the way — searches,
/// saved memories, thinking, sources — above it and the actions you can take underneath.
struct MessageRow: View {
  let message: ChatMessage
  let image: CGImage?
  let isStreaming: Bool
  let isReplacedByEdit: Bool
  let canEdit: Bool
  let canRegenerate: Bool
  let onEdit: () -> Void
  let onRegenerate: () -> Void
  let onSelectText: () -> Void
  let onShowStats: () -> Void
  let onShowImage: () -> Void

  @State private var didCopy = false

  private var isUser: Bool { message.role == .user }

  var body: some View {
    VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
      if isUser {
        userMessage
      } else {
        assistantMessage
        actionRow
      }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    .opacity(isReplacedByEdit ? 0.4 : 1)
  }

  // MARK: - Your message

  private var userMessage: some View {
    HStack(spacing: 0) {
      // Keeps the bubble off the left edge however long the message is.
      Spacer(minLength: 44)
      VStack(alignment: .trailing, spacing: 6) {
        if image != nil { photo }
        if !message.text.isEmpty {
          Text(message.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(ChatStyle.userBubble, in: bubbleShape)
            .contentShape(bubbleShape)
            .contentShape(.contextMenuPreview, bubbleShape)
            .onTapGesture { if canEdit { onEdit() } }
            .contextMenu { menuItems }
            .accessibilityHint(canEdit ? "Double-tap to edit and resend" : "")
        }
      }
    }
  }

  private var bubbleShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: ChatStyle.messageCorner, style: .continuous)
  }

  /// A photo sits above the bubble rather than inside it. Tapping it opens it full screen.
  @ViewBuilder
  private var photo: some View {
    if let image {
      Image(image, scale: 1, label: Text("Photo"))
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 240, maxHeight: 240, alignment: isUser ? .trailing : .leading)
        .clipShape(bubbleShape)
        .onTapGesture(perform: onShowImage)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the photo full screen")
    }
  }

  // MARK: - The reply

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let queries = message.searchQueries, !queries.isEmpty {
        activityLabel(
          queries.map { "“\($0)”" }.joined(separator: ", "), systemImage: "magnifyingglass")
      }
      if let saved = message.savedMemories, !saved.isEmpty {
        activityLabel("Saved to memory: \(saved.joined(separator: "; "))", systemImage: "brain")
      }
      if !message.thinking.isEmpty { thinking }
      if image != nil { photo }

      if !message.text.isEmpty {
        if message.isError {
          Text(message.text)
            .foregroundStyle(.red)
        } else {
          MarkdownView(text: message.text)
        }
      } else if isStreaming && message.thinking.isEmpty {
        workingIndicator
      }

      if let sources = message.sources, !sources.isEmpty { sourceList(sources) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.contextMenuPreview, bubbleShape)
    .contextMenu { menuItems }
  }

  private func activityLabel(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.footnote)
      .foregroundStyle(.secondary)
  }

  private var thinking: some View {
    DisclosureGroup("Thinking") {
      Text(message.thinking)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
    .font(.footnote)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(ChatStyle.fieldFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  /// What the model is busy with before any words arrive.
  private var workingIndicator: some View {
    HStack(spacing: 8) {
      ProgressView()
      if message.sources != nil {
        Text("Reading results…")
      } else if message.searchQueries != nil {
        Text("Searching the web…")
      } else {
        Text("Thinking…")
      }
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
  }

  /// Numbered to match the model's [1], [2] citations.
  private func sourceList(_ sources: [WebSource]) -> some View {
    DisclosureGroup("Sources (\(sources.count))") {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
          Link(destination: source.url) {
            VStack(alignment: .leading, spacing: 2) {
              Text("[\(index + 1)] \(source.title)")
                .lineLimit(2)
              Text(
                [source.kind, source.url.host() ?? source.url.absoluteString, source.age]
                  .compactMap { $0 }.joined(separator: " · ")
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
          }
        }
      }
      .padding(.top, 4)
    }
    .font(.footnote)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(ChatStyle.fieldFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  // MARK: - Under the reply

  /// The row of small buttons under a finished reply: copy it, select part of it, ask for another
  /// one, and see how fast it was written.
  @ViewBuilder
  private var actionRow: some View {
    if !isStreaming && (!message.text.isEmpty || message.stats != nil || canRegenerate) {
      HStack(spacing: 20) {
        #if canImport(UIKit)
          if !message.text.isEmpty {
            actionButton(
              didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc"
            ) {
              UIPasteboard.general.string = message.text
              didCopy = true
              Task {
                try? await Task.sleep(for: .seconds(2))
                didCopy = false
              }
            }
          }
        #endif
        if canRegenerate {
          actionButton("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
        }
        if let stats = message.stats {
          Button(action: onShowStats) {
            Label(Self.shortSummary(stats), systemImage: "speedometer")
              .font(.caption)
              .lineLimit(1)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Reply speed, \(Self.summary(stats))")
          .accessibilityHint("Shows the measurements for this reply")
        }
        Spacer(minLength: 0)
      }
      .foregroundStyle(.secondary)
      .padding(.top, 2)
    }
  }

  private func actionButton(
    _ title: String, systemImage: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 15))
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  /// Long-press menu: copy the whole message, select part of it, ask for another reply, or — for
  /// your own messages — edit and resend.
  @ViewBuilder
  private var menuItems: some View {
    if isUser {
      Button("Edit and resend", systemImage: "pencil", action: onEdit)
        .disabled(!canEdit)
    }
    if !isUser, canRegenerate {
      Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
    }
    #if canImport(UIKit)
      Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        .disabled(message.text.isEmpty)
      Button("Select Text", systemImage: "selection.pin.in.out", action: onSelectText)
        .disabled(message.text.isEmpty)
    #endif
  }

  /// What fits in the row under a reply: how fast it was written, or how long it took when the
  /// engine didn't count tokens.
  private static func shortSummary(_ stats: ReplyStats) -> String {
    if let rate = stats.decodeTokensPerSecond { return String(format: "%.1f tok/s", rate) }
    return String(format: "%.1fs", stats.totalSeconds)
  }

  /// The whole line, read out by VoiceOver: "212 tokens · 24.8 tok/s · 0.9s to first token · GPU".
  private static func summary(_ stats: ReplyStats) -> String {
    var parts: [String] = []
    if let tokens = stats.replyTokens { parts.append("\(tokens.formatted()) tokens") }
    if let rate = stats.decodeTokensPerSecond { parts.append(String(format: "%.1f tok/s", rate)) }
    if let firstToken = stats.timeToFirstToken {
      parts.append(String(format: "%.1fs to first token", firstToken))
    }
    if parts.isEmpty { parts.append(String(format: "%.1fs", stats.totalSeconds)) }
    parts.append(stats.producedBy)
    return parts.joined(separator: " · ")
  }
}
