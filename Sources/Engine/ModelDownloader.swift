import CryptoKit
import Foundation
import Observation

/// Downloads a model from anvilai.com and assembles it on the phone.
///
/// The catalog serves a model as a list of parts, because a file that size can't be hosted as one
/// asset. Each part is downloaded, checked against its SHA-256, appended to the file being built,
/// and deleted — so the phone only ever needs the model's own size free, plus one part. Progress is
/// recorded after every part, which is what makes an interrupted download resumable.
@MainActor
@Observable
final class ModelDownloader {
  enum Phase: Equatable {
    case idle
    case downloading
    case checking
    case installing
    case finished
    case failed(String)
  }

  private(set) var phase: Phase = .idle
  private(set) var model: CatalogModel?
  /// Parts checked and written into the file. Several more may be in flight behind them.
  private(set) var partsCompleted = 0
  private(set) var partCount = 0
  private(set) var receivedBytes: Int64 = 0
  private(set) var totalBytes: Int64 = 0

  private var inFlight: [Int: Task<URL, Error>] = [:]
  private var partProgress: [Int: Int64] = [:]
  private var appendedBytes: Int64 = 0

  /// Bytes other downloads still need, counted against free space before this one starts or
  /// carries on. Set by the library, which can see them all.
  var reservedElsewhere: Int64 = 0

  /// Downloading several gigabytes over a cellular plan is rarely what someone wants, so it's off
  /// until they say otherwise. One setting for every download; `ModelLibrary` owns the switch.
  static var allowsCellular: Bool {
    get { UserDefaults.standard.bool(forKey: cellularKey) }
    set { UserDefaults.standard.set(newValue, forKey: cellularKey) }
  }

  private static let cellularKey = "modelDownloadAllowsCellular"

  /// The signed transaction for the subscription, when there is one — see
  /// `ProAccess.subscriptionProof`. The root view keeps this in step with the App
  /// Store, the same way it does `ModelLibrary.proUnlocked`, so a download that starts
  /// after a subscription lapses has nothing to show and is refused.
  static var subscriptionProof: String?
  private static let maximumAttempts = 3

  var isActive: Bool {
    switch phase {
    case .downloading, .checking, .installing: true
    case .idle, .finished, .failed: false
    }
  }

  var fraction: Double {
    totalBytes > 0 ? min(Double(receivedBytes) / Double(totalBytes), 1) : 0
  }

  /// What this download still has to fetch.
  var remainingBytes: Int64 { max(totalBytes - receivedBytes, 0) }

  /// Downloads that were still unfinished when the app last closed, any of which can be carried on.
  static var interrupted: [CatalogModel] { ModelDownloadFiles.savedStates().map(\.model) }

  func run(_ model: CatalogModel) async {
    self.model = model
    partCount = model.parts.count
    totalBytes = model.sizeBytes
    ModelDownloadSession.shared.activate()
    do {
      try await download(model)
      phase = .finished
    } catch is CancellationError {
      phase = .idle
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// Cuts this download's transfers now — another model's carry on — so `run` returns rather than
  /// waiting for the part in hand to land. What has been fetched stays on disk: the library throws
  /// it away once `run` has returned, or a resume picks it up.
  func stop() {
    cancelInFlight()
    phase = .idle
  }

  private func cancelInFlight() {
    for task in inFlight.values { task.cancel() }
    inFlight.removeAll()
    partProgress.removeAll()
  }

  /// Hands the background session every part that isn't in hand yet, all at once, and leaves the
  /// scheduling of them to iOS.
  ///
  /// This used to keep a rolling window of four parts topped up, which was the obvious thing and
  /// the wrong one: topping the window up is work this app does, and this app doesn't run while
  /// someone is somewhere else on their phone. A download left in the background got as far as the
  /// window — four parts of Anvil Core's five, four of Anvil Raw's eight — and stopped there until
  /// the app was opened again. Enqueued up front, the whole model comes down whether the app is on
  /// the screen or not, and what is left for the app is the fast local half: checking a part and
  /// appending it.
  ///
  /// Disk doesn't pay for it. A staged part is deleted as it is appended, so what is staged and
  /// what is already in the file being built are two halves of one model: the peak is the model
  /// plus the one part being appended, which is what `storageShortfall` reserves either way.
  private func startDownloads(from index: Int, in model: CatalogModel) {
    for position in index..<model.parts.count where inFlight[position] == nil {
      let part = model.parts[position]
      partProgress[position] = 0
      // Only a Pro model's parts carry it: a free model is free to anyone, and sending
      // a subscription with a request for Anvil Core would say otherwise.
      let proof = (model.isPro ? Self.subscriptionProof : nil)
      inFlight[position] = Task { [self] in
        try await fetch(part, proof: proof) { written in
          Task { @MainActor in
            self.noteProgress(of: position, bytes: min(written, part.sizeBytes))
          }
        }
      }
    }
  }

  private func noteProgress(of position: Int, bytes: Int64) {
    // A part that has already been appended is no longer counted separately.
    guard partProgress[position] != nil else { return }
    partProgress[position] = bytes
    receivedBytes = appendedBytes + partProgress.values.reduce(0, +)
  }

  private func download(_ model: CatalogModel) async throws {
    // A half-finished download of an older version of this model is of no use now.
    if let state = ModelDownloadFiles.loadState(for: model.id), state.model.version != model.version {
      ModelDownloadFiles.discard(model)
    }

    var nextPart = min(ModelDownloadFiles.loadState(for: model.id)?.nextPart ?? 0, model.parts.count)
    try ModelDownloadFiles.requireSpace(for: model, from: nextPart, reserving: reservedElsewhere)

    let destination = try ModelDownloadFiles.partialURL(for: model)
    var badChecksums = 0
    appendedBytes = model.parts.prefix(nextPart).reduce(Int64(0)) { $0 + $1.sizeBytes }
    partsCompleted = nextPart
    receivedBytes = appendedBytes
    defer { cancelInFlight() }

    // Parts arrive in whatever order the network gives them, but they are only ever appended in
    // order: the file being built is always a correct prefix of the finished model, which is what
    // lets an interrupted download resume from a count rather than a byte offset.
    while nextPart < model.parts.count {
      try Task.checkCancellation()
      startDownloads(from: nextPart, in: model)
      phase = .downloading

      guard let download = inFlight[nextPart] else { continue }
      let part = model.parts[nextPart]
      let staged: URL
      do {
        staged = try await download.value
      } catch {
        inFlight[nextPart] = nil
        partProgress[nextPart] = nil
        throw error
      }
      inFlight[nextPart] = nil

      try Task.checkCancellation()
      phase = .checking
      do {
        try await Task.detached(priority: .userInitiated) {
          try ModelDownloadFiles.appendVerifying(staged, to: destination, matches: part.sha256)
          try? FileManager.default.removeItem(at: staged)
        }.value
      } catch ModelDownloadFiles.Failure.checksum {
        // A part that arrived damaged is worth fetching once more before giving up.
        try? FileManager.default.removeItem(at: staged)
        partProgress[nextPart] = nil
        badChecksums += 1
        guard badChecksums < 2 else { throw ModelDownloadFiles.Failure.checksum }
        continue
      }

      partProgress[nextPart] = nil
      nextPart += 1
      partsCompleted = nextPart
      appendedBytes += part.sizeBytes
      receivedBytes = appendedBytes + partProgress.values.reduce(0, +)
      ModelDownloadFiles.saveState(ModelDownloadState(model: model, nextPart: nextPart))
    }

    try Task.checkCancellation()
    cancelInFlight()
    phase = .installing
    try await Task.detached(priority: .userInitiated) {
      try ModelDownloadFiles.finish(model)
    }.value
  }

  /// Retries a part a couple of times. A connection dropping part way through three gigabytes is
  /// ordinary, and only the part in hand has to be fetched again.
  private func fetch(
    _ part: CatalogPart, proof: String?, onProgress: @escaping @Sendable (Int64) -> Void
  ) async throws -> URL {
    var attempt = 1
    while true {
      do {
        return try await ModelDownloadSession.shared.download(
          part, allowsCellular: Self.allowsCellular, proof: proof
        ) { written, _ in onProgress(written) }
      } catch {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
          throw CancellationError()
        }
        guard attempt < Self.maximumAttempts else { throw error }
        try await Task.sleep(for: .seconds(attempt * 3))
        attempt += 1
      }
    }
  }
}

/// What a resumable download has to remember: which model, and how much of it is already in the file
/// being built.
struct ModelDownloadState: Codable {
  let model: CatalogModel
  var nextPart: Int
}

/// A model that was downloaded, so the app can name it on screen and tell whether the catalog has a
/// newer version. One record per file, written next to the model files.
struct InstalledModel: Codable {
  let id: String
  let name: String
  let version: String
  let fileName: String
  /// Whether the catalog had it as part of Anvil Pro. Optional so records from before the flag
  /// still read; those were all free.
  var pro: Bool? = nil
  /// Text or image. Optional for the same reason; the records before it were all text.
  var kind: ModelKind? = nil
  /// Whether the catalog recommends it — Anvil Core — which makes it the model the chat falls
  /// back to. Optional for the same reason.
  var recommended: Bool? = nil
  /// For an image model, what its folder held when it was checked and recorded, to the byte —
  /// so a later look at the folder can tell whether it is still all there. Optional: records
  /// from before this have nothing to measure against, and are checked file by file.
  var unpackedBytes: Int64? = nil
}

/// The file work behind a download. Not tied to an actor, so hashing and copying gigabytes stays off
/// the main thread.
enum ModelDownloadFiles {
  enum Failure: LocalizedError {
    case checksum
    case assembledChecksum
    case notEnoughSpace(needed: Int64, free: Int64)

    var errorDescription: String? {
      switch self {
      case .checksum:
        return "Part of the download arrived damaged."
      case .assembledChecksum:
        return "The finished file didn't match its checksum, so it was thrown away. Try again "
          + "downloads it afresh."
      case .notEnoughSpace(let needed, let free):
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "This model needs \(format(needed)) free, and there is \(format(free))."
      }
    }
  }

  /// One record per download in progress, so two models can be on their way at once.
  static func stateFileName(for id: String) -> String { "download-\((id as NSString).lastPathComponent).json" }
  static let installedFileName = "installed.json"
  private static let incomingDirectoryName = "Incoming"
  private static let partialExtension = "partial"
  private static let chunkSize = 8 * 1024 * 1024

  /// Where a finished part waits to be checked and appended.
  static func incomingDirectory() throws -> URL {
    let directory = try ModelFiles.modelsDirectory()
      .appendingPathComponent(incomingDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// The file the parts are appended to. It only becomes a `.litertlm` once every part is in, so a
  /// half-finished download is never mistaken for a model.
  static func partialURL(for model: CatalogModel) throws -> URL {
    try ModelFiles.modelsDirectory()
      .appendingPathComponent(model.fileName + "." + partialExtension)
  }

  static func stage(_ location: URL, as name: String) throws -> URL {
    // Whatever the server said, the name is only ever used as a file name here.
    let safe = (name as NSString).lastPathComponent
    let destination = try incomingDirectory().appendingPathComponent(safe)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: location, to: destination)
    return destination
  }

  /// A part that finished while the app was closed, if it looks complete.
  static func stagedPart(_ part: CatalogPart) -> URL? {
    guard let staged = try? incomingDirectory().appendingPathComponent(part.name),
      ModelFiles.fileSize(of: staged) == part.sizeBytes
    else { return nil }
    return staged
  }

  static func verify(_ url: URL, matches expected: String) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == expected.lowercased() else { throw Failure.checksum }
  }

  /// Appends a part to the file being built and checks it against the catalog's hash on the way
  /// past, rolling back if either the write fails (a full disk, say) or the part turns out to be the
  /// wrong bytes — so the file never holds half a part or a damaged one.
  ///
  /// One pass, not two. Hashing a part and then copying it read every byte of every part twice, and
  /// a model is gigabytes: the second read bought nothing, since the bytes are already in hand on
  /// their way into the file. The cost of being wrong is a truncate, which is what a failed write
  /// already did.
  static func appendVerifying(_ url: URL, to destination: URL, matches expected: String) throws {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: destination.path) {
      fileManager.createFile(atPath: destination.path, contents: nil)
    }
    let reader = try FileHandle(forReadingFrom: url)
    let writer = try FileHandle(forWritingTo: destination)
    defer {
      try? reader.close()
      try? writer.close()
    }
    let start = try writer.seekToEnd()
    var hasher = SHA256()
    do {
      while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
        hasher.update(data: chunk)
        try writer.write(contentsOf: chunk)
      }
      let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      guard digest == expected.lowercased() else { throw Failure.checksum }
      try writer.synchronize()
    } catch {
      try? writer.truncate(atOffset: start)
      throw error
    }
  }

  /// Puts the finished download beside whatever is already installed. Only a model with the same
  /// file name — the same model, downloaded again — is replaced. An image model is an archive, and
  /// is unpacked into its own folder rather than kept as the file that arrived.
  ///
  /// The whole file is checked against the catalog's hash first. Every part was checked on the way
  /// in, but the file is what the engine opens, and a part appended twice or out of order across
  /// an interrupted download would pass every part and still be no model at all. A mismatch throws
  /// the assembly away along with the record of how far it got, so trying again starts clean
  /// instead of installing the same file twice.
  /// Throws away an unpacking that never finished: the app was closed part way through expanding
  /// an archive, and the half-written folder beside the model is of no use to anyone. Called once at
  /// launch, before anything starts unpacking again, so it can never meet one in progress.
  static func discardAbandonedUnpacking() {
    let fileManager = FileManager.default
    guard let models = try? ModelFiles.modelsDirectory(),
      let contents = try? fileManager.contentsOfDirectory(
        at: models, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    else { return }
    for url in contents where url.pathExtension == "unpacking" {
      try? fileManager.removeItem(at: url)
    }
  }

  static func finish(_ model: CatalogModel) throws {
    let fileManager = FileManager.default
    let models = try ModelFiles.modelsDirectory()
    let partial = try partialURL(for: model)

    do {
      try verify(partial, matches: model.sha256)
    } catch {
      discard(model)
      throw Failure.assembledChecksum
    }

    var destination: URL
    switch model.modelKind {
    case .text:
      destination = models.appendingPathComponent(model.fileName)
      try? fileManager.removeItem(at: destination)
      try fileManager.moveItem(at: partial, to: destination)
    case .image:
      destination = models.appendingPathComponent(
        ModelFiles.imageModelName(for: model.id), isDirectory: true)
      // Unpacked beside where it is going and moved in whole, rather than expanded into the place
      // itself.
      //
      // Expanding into the place itself meant that anything stopping the app part way through left
      // a folder with some of a model in it — and iOS stopping the app here is the ordinary case,
      // not the rare one: a gigabyte is being written out while a chat model holds the memory.
      // Nothing downstream could tell that folder from a finished one, because installed models are
      // found by looking for the folder rather than for what is inside it. So half a model counted
      // as a whole one, the app went on offering pictures, and the first one asked for failed on
      // whichever file the unpacking never reached. A move within a volume is atomic: the folder is
      // either not there at all or all there.
      let staging = destination.appendingPathExtension("unpacking")
      try? fileManager.removeItem(at: staging)
      // Room for the unpacked folder beside the archive it comes from, checked before a byte
      // is written: both exist at once until the move, and an unpack that runs out of disk
      // stops short without saying so — every entry past the stop an empty file.
      let unpacked = model.unpackedBytes ?? ModelFiles.fileSize(of: partial) ?? model.sizeBytes
      if let free = freeBytes(), free < unpacked + storageBuffer {
        throw Failure.notEnoughSpace(needed: unpacked + storageBuffer, free: free)
      }
      do {
        try ImageArchive.expand(partial, into: staging)
        // And what came out is measured against what should have, to the byte.
        try ImageArchive.requireComplete(staging, unpackedBytes: model.unpackedBytes)
      } catch {
        // Half a folder is no model; the archive stays so trying again is only the unpacking.
        try? fileManager.removeItem(at: staging)
        throw error
      }
      try? fileManager.removeItem(at: destination)
      try fileManager.moveItem(at: staging, to: destination)
      try? fileManager.removeItem(at: partial)
    }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try destination.setResourceValues(values)

    let installedName = destination.lastPathComponent
    var records = installedModels().filter { $0.fileName != installedName }
    records.append(
      InstalledModel(
        id: model.id, name: model.name, version: model.version, fileName: installedName,
        pro: model.isPro, kind: model.modelKind, recommended: model.isRecommended,
        unpackedBytes: model.unpackedBytes))
    try writeInstalled(records)

    discard(model)
  }

  static func loadState(for id: String) -> ModelDownloadState? {
    guard let url = try? ModelFiles.modelsDirectory().appendingPathComponent(stateFileName(for: id)),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(ModelDownloadState.self, from: data)
  }

  /// Every download that was under way, in no particular order.
  static func savedStates() -> [ModelDownloadState] {
    guard let models = try? ModelFiles.modelsDirectory(),
      let files = try? FileManager.default.contentsOfDirectory(
        at: models, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    else { return [] }
    return files
      .filter { $0.lastPathComponent.hasPrefix("download-") && $0.pathExtension == "json" }
      .compactMap { url in
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ModelDownloadState.self, from: $0) }
      }
      .sorted { $0.model.name < $1.model.name }
  }

  static func saveState(_ state: ModelDownloadState) {
    guard
      let url = try? ModelFiles.modelsDirectory().appendingPathComponent(
        stateFileName(for: state.model.id)),
      let data = try? JSONEncoder().encode(state)
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  /// Removes the file being built for `model`, its staged parts, and the record of how far it
  /// got. Another model's download, and every installed model, are left alone.
  static func discard(_ model: CatalogModel) {
    let fileManager = FileManager.default
    guard let models = try? ModelFiles.modelsDirectory() else { return }
    try? fileManager.removeItem(at: models.appendingPathComponent(stateFileName(for: model.id)))
    if let partial = try? partialURL(for: model) { try? fileManager.removeItem(at: partial) }
    if let incoming = try? incomingDirectory() {
      for part in model.parts {
        try? fileManager.removeItem(at: incoming.appendingPathComponent(part.name))
      }
    }
  }

  /// Every model that was downloaded, as it was named. Earlier builds wrote one record rather than
  /// a list; both are read, so an update doesn't lose the name of the model already there.
  static func installedModels() -> [InstalledModel] {
    guard let url = try? ModelFiles.modelsDirectory().appendingPathComponent(installedFileName),
      let data = try? Data(contentsOf: url)
    else { return [] }
    if let records = try? JSONDecoder().decode([InstalledModel].self, from: data) { return records }
    if let record = try? JSONDecoder().decode(InstalledModel.self, from: data) { return [record] }
    return []
  }

  static func installed(named fileName: String) -> InstalledModel? {
    installedModels().first { $0.fileName == fileName }
  }

  static func forget(_ fileName: String) {
    try? writeInstalled(installedModels().filter { $0.fileName != fileName })
  }

  private static func writeInstalled(_ records: [InstalledModel]) throws {
    let url = try ModelFiles.modelsDirectory().appendingPathComponent(installedFileName)
    try JSONEncoder().encode(records).write(to: url, options: .atomic)
  }

  static func freeBytes() -> Int64? {
    guard let models = try? ModelFiles.modelsDirectory(),
      let values = try? models.resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    else { return nil }
    return values.volumeAvailableCapacityForImportantUsage
  }

  /// Room left over once a model is installed. Five gigabytes: enough that the phone goes on
  /// working normally afterwards rather than merely fitting the model — iOS not warning about
  /// space, photos and everything else still with somewhere to go. The bar on the model screens
  /// draws this same number, so what it shows in red is exactly what this refuses.
  static let storageBuffer: Int64 = 5_000_000_000

  /// What a download needs free to start or carry on: what is left to fetch, the one part being
  /// staged, the buffer, and whatever other downloads under way still need (`reserving`). Nil when
  /// there is room, or when the phone won't say how much there is.
  static func storageShortfall(
    for model: CatalogModel, from nextPart: Int, reserving: Int64 = 0
  ) -> (needed: Int64, free: Int64)? {
    let remaining = model.parts.dropFirst(nextPart).reduce(Int64(0)) { $0 + $1.sizeBytes }
    let largestPart = model.parts.map(\.sizeBytes).max() ?? 0
    var needed = remaining + largestPart + storageBuffer
    if nextPart == 0 { needed = max(needed, model.requiredFreeBytes) }
    needed += reserving
    guard let free = freeBytes(), free < needed else { return nil }
    return (needed, free)
  }

  /// Checks there is room for what is left to download, plus the one part being staged.
  static func requireSpace(for model: CatalogModel, from nextPart: Int, reserving: Int64 = 0) throws {
    if let short = storageShortfall(for: model, from: nextPart, reserving: reserving) {
      throw Failure.notEnoughSpace(needed: short.needed, free: short.free)
    }
  }

  /// The words for the alert, for `name`: what it needs, what there is, and what to do.
  static func storageMessage(for name: String, needed: Int64, free: Int64) -> String {
    let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    return "\(name) needs \(format(needed)) free, including \(format(storageBuffer)) to spare, "
      + "and this iPhone has \(format(free)). Free up some space and try again."
  }
}
