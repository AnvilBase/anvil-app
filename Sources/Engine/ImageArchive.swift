import AppleArchive
import Foundation
import System

/// Unpacks an Anvil Dream download.
///
/// An image model is not one file but a folder of compiled Core ML models and tokenizer files, so
/// it travels as an Apple Archive (`.aar`, made with `aa` on a Mac) and is expanded here with the
/// framework iOS ships for exactly that. Nothing third-party, and no zip.
enum ImageArchive {
  enum Failure: LocalizedError {
    case cannotOpen
    case cannotExtract

    var errorDescription: String? {
      switch self {
      case .cannotOpen: "The downloaded model archive couldn't be opened."
      case .cannotExtract: "The downloaded model archive couldn't be unpacked."
      }
    }
  }

  static func expand(_ archive: URL, into directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard
      let file = ArchiveByteStream.fileStream(
        path: FilePath(archive.path), mode: .readOnly, options: [],
        permissions: FilePermissions(rawValue: 0o644))
    else { throw Failure.cannotOpen }
    defer { try? file.close() }
    guard let decompress = ArchiveByteStream.decompressionStream(readingFrom: file) else {
      throw Failure.cannotOpen
    }
    defer { try? decompress.close() }
    guard let decode = ArchiveStream.decodeStream(readingFrom: decompress) else {
      throw Failure.cannotOpen
    }
    defer { try? decode.close() }
    guard
      let extract = ArchiveStream.extractStream(
        extractingTo: FilePath(directory.path), flags: [.ignoreOperationNotPermitted])
    else { throw Failure.cannotExtract }
    defer { try? extract.close() }
    _ = try ArchiveStream.process(readingFrom: decode, writingTo: extract)
  }
}
