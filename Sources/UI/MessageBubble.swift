import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// One message: your photo and text on the right, the model's reply on the left with whatever it did
/// along the way — searches, saved memories, thinking, sources — and the measurements underneath.
struct MessageBubble: View {
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

  var body: some View {
    HStack {
      if message.role == .user { Spacer(minLength: 40) }

      VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
        if message.role == .user {
          messageContent
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
            .onTapGesture { if canEdit { onEdit() } }
            .contextMenu { menuItems }
            .accessibilityHint(canEdit ? "Double-tap to edit and resend" : "")
        } else {
          messageContent
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
            .contextMenu { menuItems }
        }

        if message.role == .assistant, message.stats != nil || canRegenerate {
          HStack(spacing: 14) {
            if let stats = message.stats {
              Button(action: onShowStats) {
                Label(Self.summary(stats), systemImage: "speedometer")
              }
              .accessibilityHint("Shows the measurements for this reply")
            }
            if canRegenerate {
              Button(action: onRegenerate) {
                Label("Regenerate", systemImage: "arrow.clockwise")
              }
            }
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
          .buttonStyle(.plain)
        }
      }

      if message.role == .assistant { Spacer(minLength: 40) }
    }
    .opacity(isReplacedByEdit ? 0.4 : 1)
  }

  /// Long-press menu: copy the whole message, select part of it, regenerate the last reply, or — for
  /// your own messages — edit and resend.
  @ViewBuilder
  private var menuItems: some View {
    if message.role == .user {
      Button("Edit and resend", systemImage: "pencil", action: onEdit)
        .disabled(!canEdit)
    }
    if message.role == .assistant, canRegenerate {
      Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
    }
    #if canImport(UIKit)
      Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        .disabled(message.text.isEmpty)
      Button("Select Text", systemImage: "selection.pin.in.out", action: onSelectText)
        .disabled(message.text.isEmpty)
    #endif
  }

  /// A photo sits above the coloured bubble, not inside it. Tapping it opens it full screen.
  private var messageContent: some View {
    VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
      if let image {
        Image(image, scale: 1, label: Text("Photo"))
          .resizable()
          .scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .frame(
            maxWidth: 220, maxHeight: 220,
            alignment: message.role == .user ? .trailing : .leading
          )
          // Takes priority over the bubble's tap-to-edit.
          .onTapGesture(perform: onShowImage)
          .accessibilityAddTraits(.isButton)
          .accessibilityHint("Shows the photo full screen")
      }
      if hasBubbleContent {
        bubble
      }
    }
  }

  /// A photo sent without text doesn't get an empty bubble under it.
  private var hasBubbleContent: Bool {
    !message.text.isEmpty || !message.thinking.isEmpty || isStreaming
      || message.searchQueries?.isEmpty == false || message.sources?.isEmpty == false
      || message.savedMemories?.isEmpty == false
  }

  private var bubble: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let queries = message.searchQueries, !queries.isEmpty {
        Label(queries.map { "“\($0)”" }.joined(separator: ", "), systemImage: "magnifyingglass")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let saved = message.savedMemories, !saved.isEmpty {
        Label("Saved to memory: \(saved.joined(separator: "; "))", systemImage: "brain")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if !message.thinking.isEmpty {
        DisclosureGroup("Thinking") {
          Text(message.thinking)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .font(.footnote)
      }
      if !message.text.isEmpty {
        if message.role == .assistant && !message.isError {
          MarkdownView(text: message.text)
        } else {
          Text(message.text)
        }
      } else if isStreaming && message.thinking.isEmpty {
        HStack(spacing: 8) {
          ProgressView()
          if message.sources != nil {
            Text("Reading results…")
          } else if message.searchQueries != nil {
            Text("Searching the web…")
          }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      if let sources = message.sources, !sources.isEmpty {
        sourceList(sources)
      }
    }
    .padding(12)
    .foregroundStyle(foreground)
    .background(background, in: RoundedRectangle(cornerRadius: 16))
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
  }

  /// One line under a reply, such as "212 tokens · 24.8 tok/s · 0.9s to first token · GPU".
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

  private var foreground: AnyShapeStyle {
    if message.role == .user { return AnyShapeStyle(Color.white) }
    if message.isError { return AnyShapeStyle(Color.red) }
    return AnyShapeStyle(HierarchicalShapeStyle.primary)
  }

  private var background: AnyShapeStyle {
    message.role == .user
      ? AnyShapeStyle(Color.accentColor)
      : AnyShapeStyle(Color.secondary.opacity(0.15))
  }
}
