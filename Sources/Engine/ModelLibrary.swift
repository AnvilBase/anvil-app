import Foundation
import Observation

/// An imported model file. Re-importing a file with the same name still produces a different value
/// (its size or modification date differ), which is what tells the chat to reload the engine.
struct ModelFile: Hashable, Sendable {
  let url: URL
  let fileSize: Int64
  let modificationDate: Date
}

/// Finds the imported model, waits for a copy in progress to finish, and protects the file.
///
/// You copy a `.litertlm` file into the app's Documents folder over a cable (Finder's Files tab) or
/// with the Files app. Once the copy is complete the file moves into Application Support/Models,
/// which is hidden from the Files app and excluded from backups.
@MainActor
@Observable
final class ModelLibrary {
  enum State: Equatable {
    case checking
    case missing
    case waitingForCopy(fileName: String)
    case ready(ModelFile)
    case failed(String)
  }

  private(set) var state: State = .checking
  private var isRefreshing = false

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      if let incoming = try ModelFiles.firstModel(in: ModelFiles.documentsDirectory()),
        try await waitForCopyToFinish(incoming)
      {
        let file = try await Task.detached(priority: .userInitiated) {
          try ModelFiles.importModel(from: incoming)
        }.value
        setState(.ready(file))
      } else if let existing = try ModelFiles.firstModel(in: ModelFiles.modelsDirectory()) {
        setState(.ready(try ModelFiles.describe(existing)))
      } else {
        setState(.missing)
      }
    } catch is CancellationError {
      // The view that started this went away; the next refresh picks up where it left off.
    } catch {
      setState(.failed(error.localizedDescription))
    }
  }

  func removeModel() async {
    do {
      try await Task.detached { try ModelFiles.removeImportedModels() }.value
      setState(.missing)
    } catch {
      setState(.failed(error.localizedDescription))
    }
  }

  /// Returns true once the file size has held steady across consecutive checks, or false if the file
  /// disappears (a cancelled transfer). Moving a file that is still being written would leave a
  /// truncated model behind.
  private func waitForCopyToFinish(_ url: URL) async throws -> Bool {
    setState(.waitingForCopy(fileName: url.lastPathComponent))
    var lastSize = ModelFiles.fileSize(of: url)
    var stableChecks = 0
    while stableChecks < ModelFiles.requiredStableChecks {
      try await Task.sleep(for: ModelFiles.copyPollInterval)
      guard let size = ModelFiles.fileSize(of: url) else { return false }
      stableChecks = (size > 0 && size == lastSize) ? stableChecks + 1 : 0
      lastSize = size
    }
    return true
  }

  private func setState(_ newState: State) {
    if state != newState { state = newState }
  }
}

/// The file-system side of importing a model. Not tied to an actor, so the slow parts can run off the
/// main thread.
enum ModelFiles {
  static let fileExtension = "litertlm"
  static let copyPollInterval: Duration = .seconds(2)
  static let requiredStableChecks = 2

  /// Where a copied-in file lands. Visible in Finder and the Files app.
  static func documentsDirectory() throws -> URL {
    try FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
  }

  /// Where the imported model lives afterwards: private to the app and never backed up.
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

  /// Reads the size straight from disk. URL resource values are cached, which would defeat polling.
  static func fileSize(of url: URL) -> Int64? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value
  }

  static func describe(_ url: URL) throws -> ModelFile {
    var url = url
    try excludeFromBackup(&url)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ModelFile(
      url: url,
      fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
      modificationDate: attributes[.modificationDate] as? Date ?? .distantPast)
  }

  /// Moves the copied-in model into Application Support/Models, replacing any previous model.
  static func importModel(from source: URL) throws -> ModelFile {
    try removeImportedModels()
    let destination = try modelsDirectory().appendingPathComponent(source.lastPathComponent)
    try FileManager.default.moveItem(at: source, to: destination)
    return try describe(destination)
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
