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
    case incomplete(String)

    var errorDescription: String? {
      switch self {
      case .cannotOpen: "The downloaded model archive couldn't be opened."
      case .cannotExtract: "The downloaded model archive couldn't be unpacked."
      case .incomplete(let name): "The downloaded model archive was missing \(name)."
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

  /// The files a folder is not an Anvil Dream without: the tokenizer's two, a text encoder, the
  /// U-Net in one piece or in two, and the decoder.
  ///
  /// The question this asks is whether the unpacking finished, not whether the engine can run what
  /// came out of it. An older Anvil Dream is a whole folder of the wrong model and has its own
  /// answer — `DreamEngine.Failure.outdated`, which says to update it. Reading that as damage would
  /// have the app throwing away a model it only needed to replace, downloading it again, and
  /// arriving at the same conclusion.
  static func requireComplete(_ directory: URL) throws {
    let resources = DreamEngine.resources(in: directory)
    let fileManager = FileManager.default
    func present(_ name: String) -> Bool {
      fileManager.fileExists(atPath: resources.appendingPathComponent(name).path)
    }
    for name in ["merges.txt", "vocab.json", "TextEncoder.mlmodelc", "VAEDecoder.mlmodelc"]
    where !present(name) {
      throw Failure.incomplete(name)
    }
    guard present("Unet.mlmodelc")
      || (present("UnetChunk1.mlmodelc") && present("UnetChunk2.mlmodelc"))
    else { throw Failure.incomplete("Unet.mlmodelc") }
  }

  /// Whether a folder holds the whole of a model, for deciding whether what is on the phone is
  /// worth keeping.
  static func isComplete(_ directory: URL) -> Bool {
    do {
      try requireComplete(directory)
      return true
    } catch {
      return false
    }
  }
}
