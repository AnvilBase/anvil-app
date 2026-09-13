import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Reads a file someone picked into the text a message can carry.
///
/// Plain text of any kind — code, Markdown, CSV, JSON — is read as it is; a PDF is read page by
/// page for its text; rich text is flattened. The model has a context of a few thousand tokens,
/// so what is kept is the beginning of a long file, and the attachment says so.
enum FileReading {
  /// What the file picker offers. `.text` covers plain text and everything built on it.
  static let types: [UTType] = [.text, .sourceCode, .json, .commaSeparatedText, .rtf, .pdf]

  /// About 3,000 tokens' worth: room for the file, the question, and a reply in a 4,096 context.
  static let maximumCharacters = 12_000

  enum Failure: LocalizedError {
    case unreadable(String)
    case empty(String)

    var errorDescription: String? {
      switch self {
      case .unreadable(let name): "\"\(name)\" couldn't be read as text."
      case .empty(let name): "\"\(name)\" has no text in it."
      }
    }
  }

  /// Reads the file at `url`, which the picker hands over security-scoped: access is claimed for
  /// the read and released after.
  static func read(_ url: URL) throws -> FileAttachment {
    let name = url.lastPathComponent
    let claimed = url.startAccessingSecurityScopedResource()
    defer { if claimed { url.stopAccessingSecurityScopedResource() } }

    let type = UTType(filenameExtension: url.pathExtension) ?? .data
    let text: String
    if type.conforms(to: .pdf) {
      guard let document = PDFDocument(url: url) else { throw Failure.unreadable(name) }
      text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        .joined(separator: "\n\n")
    } else if type.conforms(to: .rtf) {
      let data = try Data(contentsOf: url)
      guard
        let rich = try? NSAttributedString(
          data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
          documentAttributes: nil)
      else { throw Failure.unreadable(name) }
      text = rich.string
    } else {
      let data = try Data(contentsOf: url)
      guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
      else { throw Failure.unreadable(name) }
      text = decoded
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw Failure.empty(name) }
    if trimmed.count > maximumCharacters {
      return FileAttachment(name: name, text: String(trimmed.prefix(maximumCharacters)), isTruncated: true)
    }
    return FileAttachment(name: name, text: trimmed)
  }
}
