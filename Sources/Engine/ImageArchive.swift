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
  /// The question this asks is whether the unpacking finished, not which model came out of it:
  /// Anvil Dream Lite has one text encoder and Anvil Dream two, and both are whole with the files
  /// named here.
  static func requireComplete(_ directory: URL, unpackedBytes: Int64? = nil) throws {
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

    // Existing is not enough. An unpack that stops part way leaves every entry after the
    // stop as an empty file — vocab.json, merges.txt, a decoder's weights, all present and
    // all nothing — and that passed here once, was promoted, and took the app down the
    // first time anyone asked for a picture. Nothing in the package is legitimately empty.
    var total: Int64 = 0
    if let files = fileManager.enumerator(
      at: resources, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
      options: .skipsHiddenFiles)
    {
      for case let file as URL in files {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { continue }
        let size = Int64(values?.fileSize ?? 0)
        if size == 0 { throw Failure.incomplete(file.lastPathComponent) }
        total += size
      }
    }
    // And the one file that is read by code which can't fail politely has to parse.
    let vocabulary = try Data(contentsOf: resources.appendingPathComponent("vocab.json"))
    guard (try? JSONDecoder().decode([String: Int].self, from: vocabulary)) != nil else {
      throw Failure.incomplete("vocab.json")
    }
    // A file that stopped short is neither missing nor empty, and only the total finds it.
    if let unpackedBytes, total != unpackedBytes {
      throw Failure.incomplete("\(total) of \(unpackedBytes) bytes")
    }
  }

  /// Whether a folder holds the whole of a model, for deciding whether what is on the phone is
  /// worth keeping.
  static func isComplete(_ directory: URL, unpackedBytes: Int64? = nil) -> Bool {
    do {
      try requireComplete(directory, unpackedBytes: unpackedBytes)
      return true
    } catch {
      return false
    }
  }
}
