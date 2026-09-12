import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// Renders the Markdown models write: headings, fenced code blocks, lists, quotes, tables, rules,
/// and inline styles.
///
/// SwiftUI's `Text` styles inline Markdown only, and the app ships no third-party dependencies, so
/// block structure is parsed here. It works while a reply streams: an unclosed code fence renders as
/// the code written so far rather than as stray backticks.
struct MarkdownView: View {
  let text: String

  var body: some View {
    let blocks = MarkdownParser.blocks(from: text)
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        view(for: block)
      }
    }
  }

  @ViewBuilder
  private func view(for block: MarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(Self.inline(text))
        .font(Self.headingFont(level))
        .fontWeight(.semibold)

    case .paragraph(let text):
      Text(Self.inline(text))

    case .code(let language, let code):
      CodeBlockView(language: language, code: code)

    case .list(let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.marker)
              .monospacedDigit()
            Text(Self.inline(item.text))
          }
          .padding(.leading, CGFloat(item.level) * 18)
        }
      }

    case .quote(let text):
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(.secondary)
          .frame(width: 3)
        Text(Self.inline(text))
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)

    case .rule:
      Divider()

    case .table(let header, let rows):
      TableBlockView(header: header, rows: rows)
    }
  }

  static func inline(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: inlineMathAsCode(text), options: options))
      ?? AttributedString(text)
  }

  /// There's no math renderer, so LaTeX like $O(n)$ is shown as code. Dollar amounts such as
  /// "$5 to $10" don't match because the closing $ must directly follow a non-space character.
  private static func inlineMathAsCode(_ text: String) -> String {
    guard text.contains("$") else { return text }
    return text.replacingOccurrences(
      of: #"\$(?=\S)([^$\n]*?\S)\$(?!\d)"#, with: "`$1`", options: .regularExpression)
  }

  private static func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title2
    case 2: .title3
    default: .headline
    }
  }
}

enum MarkdownBlock: Equatable {
  struct ListItem: Equatable {
    let marker: String
    let level: Int
    var text: String
  }

  case heading(level: Int, text: String)
  case paragraph(String)
  case code(language: String, code: String)
  case list([ListItem])
  case quote(String)
  case rule
  case table(header: [String], rows: [[String]])
}

enum MarkdownParser {
  static func blocks(from text: String) -> [MarkdownBlock] {
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var listItems: [MarkdownBlock.ListItem] = []
    var quote: [String] = []

    func flush() {
      if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
      if !listItems.isEmpty { blocks.append(.list(listItems)) }
      if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
      paragraph = []
      listItems = []
      quote = []
    }

    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if let fence = codeFence(trimmed) {
        flush()
        let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
        // A one-line display equation: $$ x^2 $$
        if fence == "$$", trimmed.count > 4, trimmed.hasSuffix("$$") {
          blocks.append(.code(language: "math", code: String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)))
          index += 1
          continue
        }
        var code: [String] = []
        index += 1
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
          code.append(lines[index])
          index += 1
        }
        index += 1  // The closing fence, or past the end while the reply is still streaming.
        blocks.append(.code(language: fence == "$$" ? "math" : language, code: code.joined(separator: "\n")))
        continue
      }

      if trimmed.isEmpty {
        flush()
      } else if let heading = heading(trimmed) {
        flush()
        blocks.append(heading)
      } else if isRule(trimmed) {
        flush()
        blocks.append(.rule)
      } else if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
        flush()
        let header = cells(trimmed)
        var rows: [[String]] = []
        index += 2
        while index < lines.count, lines[index].contains("|") {
          rows.append(cells(lines[index]))
          index += 1
        }
        blocks.append(.table(header: header, rows: rows))
        continue
      } else if trimmed.hasPrefix(">") {
        if quote.isEmpty { flush() }
        quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
      } else if let item = listItem(line) {
        if listItems.isEmpty { flush() }
        listItems.append(item)
      } else if !listItems.isEmpty, line.first == " " || line.first == "\t" {
        // An indented line continues the previous list item.
        listItems[listItems.count - 1].text += "\n" + trimmed
      } else {
        if !listItems.isEmpty || !quote.isEmpty { flush() }
        paragraph.append(trimmed)
      }
      index += 1
    }
    flush()
    return blocks
  }

  private static func codeFence(_ line: String) -> String? {
    ["```", "~~~", "$$"].first { line.hasPrefix($0) }
  }

  private static func heading(_ line: String) -> MarkdownBlock? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = line.dropFirst(hashes)
    guard rest.isEmpty || rest.first == " " else { return nil }
    let text = rest.trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
      .trimmingCharacters(in: .whitespaces)
    return .heading(level: hashes, text: text)
  }

  /// ---, ***, or ___ (spaces allowed).
  private static func isRule(_ line: String) -> Bool {
    let compact = line.filter { $0 != " " }
    guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
    return compact.allSatisfy { $0 == first }
  }

  private static func listItem(_ line: String) -> MarkdownBlock.ListItem? {
    let leading = line.prefix { $0 == " " || $0 == "\t" }
    let spaces = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    // Models nest with 2 to 4 spaces per level.
    let level = min((spaces + 3) / 4, 4)
    let body = line.dropFirst(leading.count)

    if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
      let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
      return MarkdownBlock.ListItem(marker: level == 0 ? "•" : "◦", level: level, text: text)
    }
    let digits = body.prefix { $0.isNumber }
    let afterDigits = body.dropFirst(digits.count)
    if (1...3).contains(digits.count), let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
      afterDigits.dropFirst().first == " "
    {
      let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
      return MarkdownBlock.ListItem(marker: "\(digits).", level: level, text: text)
    }
    return nil
  }

  private static func isTableSeparator(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.contains("-") && trimmed.contains("|") && trimmed.allSatisfy { "|-: ".contains($0) }
  }

  private static func cells(_ line: String) -> [String] {
    var parts = line.trimmingCharacters(in: .whitespaces)
      .split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    if parts.first == "" { parts.removeFirst() }
    if parts.last == "" { parts.removeLast() }
    return parts
  }
}

private struct CodeBlockView: View {
  let language: String
  let code: String

  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language.isEmpty ? "code" : language)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        #if canImport(UIKit)
          Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
            UIPasteboard.general.string = code
            copied = true
            Task {
              try? await Task.sleep(for: .seconds(2))
              copied = false
            }
          }
          .font(.caption)
          .buttonStyle(.borderless)
        #endif
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color.primary.opacity(0.08))

      ScrollView(.horizontal, showsIndicators: false) {
        Text(code)
          .font(.system(.footnote, design: .monospaced))
          .fixedSize(horizontal: true, vertical: false)
          .padding(10)
      }
    }
    .background(Color.primary.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }
}

private struct TableBlockView: View {
  let header: [String]
  let rows: [[String]]

  var body: some View {
    let columns = max(header.count, rows.map(\.count).max() ?? 0)
    ScrollView(.horizontal, showsIndicators: false) {
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
        GridRow {
          ForEach(0..<columns, id: \.self) { column in
            Text(MarkdownView.inline(cell(header, column)))
              .fontWeight(.semibold)
          }
        }
        Divider()
          .gridCellUnsizedAxes(.horizontal)
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            ForEach(0..<columns, id: \.self) { column in
              Text(MarkdownView.inline(cell(row, column)))
            }
          }
        }
      }
      .font(.footnote)
      .padding(10)
    }
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
  }

  private func cell(_ row: [String], _ column: Int) -> String {
    column < row.count ? row[column] : ""
  }
}
