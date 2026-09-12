import Foundation
import Observation

/// An installed model file. Installing a file with the same name again still produces a different
/// value (its size or modification date differ), which is what tells the chat to reload the engine.
struct ModelFile: Hashable, Sendable {
  let url: URL
  let fileSize: Int64
  let modificationDate: Date
  /// What to call the model on screen: the catalog name where there is one, the file name otherwise.
  let displayName: String
}

/// Finds the installed model and protects the file.
///
/// A downloaded `.litertlm` file is built up in Application Support/Models, which is hidden from the
/// Files app and excluded from backups.
@MainActor
@Observable
final class ModelLibrary {
  enum State: Equatable {
    case checking
    case missing
    case ready(ModelFile)
    case failed(String)
  }

  private(set) var state: State = .checking
  let downloader = ModelDownloader()

  private var isRefreshing = false
  private var installTask: Task<Void, Never>?

  /// A download the app closing interrupted, which can be carried on.
  var interruptedDownload: CatalogModel? {
    downloader.isActive ? nil : ModelDownloader.interrupted
  }

  /// Downloads a model from anvilai.com and loads it once it arrives.
  func install(_ model: CatalogModel) {
    guard !downloader.isActive else { return }
    installTask?.cancel()
    installTask = Task { [self] in
      await downloader.run(model)
      if downloader.phase == .finished { await refresh() }
    }
  }

  func cancelInstall() async {
    installTask?.cancel()
    _ = await installTask?.value
    installTask = nil
    downloader.discard()
  }

  func refresh() async {
    // A download owns the models folder while it runs; leave its half-built file alone.
    guard !downloader.isActive else { return }
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      if let existing = try ModelFiles.firstModel(in: ModelFiles.modelsDirectory()) {
        setState(.ready(try ModelFiles.describe(existing)))
      } else {
        setState(.missing)
      }
    } catch {
      setState(.failed(error.localizedDescription))
    }
  }

  func removeModel() async {
    do {
      await cancelInstall()
      try await Task.detached { try ModelFiles.removeImportedModels() }.value
      setState(.missing)
    } catch {
      setState(.failed(error.localizedDescription))
    }
  }

  private func setState(_ newState: State) {
    if state != newState { state = newState }
  }
}

/// The file-system side of installing a model. Not tied to an actor, so the slow parts can run off
/// the main thread.
enum ModelFiles {
  static let fileExtension = "litertlm"

  /// Where the model lives: private to the app and never backed up.
  static func modelsDirectory() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var models = support.appendingPathComponent("Models", isDirectory: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try excludeFromBackup(&models)
    return models
  }

  /// Engine caches, which make later launches much faster. Caches survives relaunches, unlike tmp,
  /// and is never backed up.
  static func cacheDirectory() throws -> URL {
    let caches = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = caches.appendingPathComponent("EngineCache", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func firstModel(in directory: URL) throws -> URL? {
    try FileManager.default
      .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      .filter { $0.pathExtension.lowercased() == fileExtension }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .first
  }

  /// Reads the size straight from disk. URL resource values are cached, which would give a stale
  /// answer for a file still being written.
  static func fileSize(of url: URL) -> Int64? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value
  }

  static func describe(_ url: URL) throws -> ModelFile {
    var url = url
    try excludeFromBackup(&url)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let installed = ModelDownloadFiles.installed()
    let name = installed?.fileName == url.lastPathComponent ? installed?.name : nil
    return ModelFile(
      url: url,
      fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
      modificationDate: attributes[.modificationDate] as? Date ?? .distantPast,
      displayName: name ?? url.deletingPathExtension().lastPathComponent)
  }

  static func removeImportedModels() throws {
    let fileManager = FileManager.default
    for file in try fileManager.contentsOfDirectory(
      at: modelsDirectory(), includingPropertiesForKeys: nil)
    {
      try fileManager.removeItem(at: file)
    }
  }

  private static func excludeFromBackup(_ url: inout URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
}
