import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Every saved chat as one Markdown file, for the share sheet.
///
/// The file is written only when something is chosen to receive it — the share sheet asks for the
/// representation, not the row — and goes into the temporary directory, which is the one place the
/// receiving app is allowed to read from. Photos and pictures are named, not embedded: a single
/// text file is something every app on the sheet can take, and a folder is not.
struct ChatExport: Transferable {
  let chats: [Chat]

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .plainText) { export in
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Anvil chats.md", isDirectory: false)
      try Data(export.markdown.utf8).write(to: url, options: .atomic)
      return SentTransferredFile(url, allowAccessingOriginalFile: false)
    }
    .suggestedFileName("Anvil chats.md")
  }

  /// The chats, newest first, each under its title with the day it started; every message under
  /// who said it, with the sources a reply cited numbered after it, the way the chat shows them.
  var markdown: String {
    var lines = ["# Anvil chats", ""]
    lines.append(
      "Exported \(Self.stamp(Date())). \(chats.count) \(chats.count == 1 ? "chat" : "chats").")
    for chat in chats {
      lines.append("")
      lines.append("---")
      lines.append("")
      lines.append("## \(chat.displayTitle)")
      lines.append("")
      lines.append("_\(Self.stamp(chat.createdAt))_")
      for message in chat.messages {
        lines.append("")
        let speaker = message.role == .user ? "You" : "Anvil"
        lines.append("**\(speaker)\(message.isError ? " (error)" : ""):**")
        if message.hasImage {
          lines.append(
            message.role == .user
              ? "_(photo)_" : "_(picture\(message.imagePrompt.map { ": \($0)" } ?? ""))_")
        }
        if !message.text.isEmpty { lines.append(message.text) }
        if let sources = message.sources, !sources.isEmpty {
          lines.append("")
          lines.append("Sources:")
          for (index, source) in sources.enumerated() {
            lines.append("\(index + 1). [\(source.title)](\(source.url.absoluteString))")
          }
        }
      }
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  private static func stamp(_ date: Date) -> String {
    date.formatted(date: .long, time: .shortened)
  }
}
