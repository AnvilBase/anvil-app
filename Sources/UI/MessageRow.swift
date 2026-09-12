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
  /// Whether to offer the measurements for this reply. They are for working on Anvil, not for
  /// using it, so the public app never shows them.
  let showsMetrics: Bool
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
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
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
  ///
  /// The frame is the size the photo actually comes out at, worked out here, rather than a
  /// flexible box it is fitted inside. A box told only how big it may get takes the whole width it
  /// is offered, and a screenshot — tall and narrow — leaves most of that empty. The corner is cut
  /// from the box, so the curve on the side the photo isn't up against lands on nothing, and the
  /// photo reads as rounded down one edge and square down the other.
  @ViewBuilder
  private var photo: some View {
    if let image {
      let size = Self.photoSize(for: image)
      Image(image, scale: 1, label: Text("Photo"))
        .resizable()
        .frame(width: size.width, height: size.height)
        .clipShape(bubbleShape)
        .onTapGesture(perform: onShowImage)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the photo full screen")
    }
  }

  /// The photo scaled to sit inside 240pt square, keeping its shape. Whichever side is longer ends
  /// up at 240 and the other follows from it, so the frame is exactly the photo and nothing else.
  private static func photoSize(for image: CGImage) -> CGSize {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    guard width > 0, height > 0 else { return CGSize(width: 240, height: 240) }
    let scale = min(240 / width, 240 / height)
    return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
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
        Group {
          if message.isError {
            Text(message.text)
              .foregroundStyle(.red)
          } else {
            MarkdownView(text: message.text)
              // Eases the growth while words arrive, so the reply flows rather than jumping a line
              // at a time. Only while streaming: a finished reply has nothing left to animate.
              .animation(isStreaming ? .easeOut(duration: 0.15) : nil, value: message.text)
          }
        }
        .transition(.opacity)
      } else if isStreaming && message.thinking.isEmpty {
        workingIndicator
          .transition(.opacity)
      }

      if let sources = message.sources, !sources.isEmpty { sourceList(sources) }
    }
    // The first words cross-fade with the indicator they replace.
    .animation(.easeOut(duration: 0.25), value: message.text.isEmpty)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.contextMenuPreview, bubbleShape)
    .contextMenu { menuItems }
  }

  private func activityLabel(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.subheadline)
      .foregroundStyle(.secondary)
  }

  private var thinking: some View {
    DisclosureGroup("Thinking") {
      Text(message.thinking)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
    .font(.subheadline)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(ChatStyle.fieldFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  /// What the model is busy with before any words arrive. Thinking is the pixels alone — there is
  /// nothing to say about it that the animation doesn't already say. Searching says what it's
  /// looking for.
  private var workingIndicator: some View {
    HStack(spacing: 8) {
      PixelThinking()
      if message.sources != nil {
        Text("Reading results…")
      } else if message.searchQueries != nil {
        Text("Searching the web…")
      }
    }
    .font(.subheadline)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(workingDescription)
  }

  private var workingDescription: String {
    if message.sources != nil { return "Reading results" }
    if message.searchQueries != nil { return "Searching the web" }
    return "Thinking"
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
              .font(.footnote)
              .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
          }
        }
      }
      .padding(.top, 4)
    }
    .font(.subheadline)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(ChatStyle.fieldFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  // MARK: - Under the reply

  /// The row of small buttons under a finished reply: copy it, select part of it, ask for another
  /// one, and see how fast it was written.
  @ViewBuilder
  private var actionRow: some View {
    if !isStreaming && (!message.text.isEmpty || message.stats != nil || canRegenerate) {
      HStack(spacing: 6) {
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
        if showsMetrics, let stats = message.stats {
          // The reading itself is behind the button rather than printed on it: it is the one thing
          // in this row that was a line of text among glyphs, which made it the loudest thing under
          // a reply and a different size from its neighbours.
          actionButton("Reply speed", systemImage: "speedometer", action: onShowStats)
            .accessibilityValue(Self.summary(stats))
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
        .font(.system(size: ChatStyle.smallControlGlyph, weight: .medium))
        .frame(width: ChatStyle.smallControl, height: ChatStyle.smallControl)
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
