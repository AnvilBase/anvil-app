import Foundation
import Observation

/// A model file on the phone. Installing a file with the same name again still produces a different
/// value (its size or modification date differ), which is what tells the chat to reload the engine.
struct ModelFile: Hashable, Sendable, Identifiable {
  let url: URL
  let fileSize: Int64
  let modificationDate: Date
  /// What to call the model on screen: the catalog name where there is one, the file name otherwise.
  let displayName: String
  /// Which catalog model it was downloaded as, and which version — nil for a file the app didn't
  /// download itself.
  let catalogID: String?
  let version: String?
  /// Downloaded as part of Anvil Pro. Usable only while Pro is active: see `ModelLibrary.proUnlocked`.
  var isPro: Bool = false
  /// The model the catalog recommends, Anvil Core: the one the chat runs on until another is
  /// chosen, and the one it comes back to.
  var isRecommended: Bool = false
  /// A text model, which the chat runs on, or an image model, which Anvil Dream makes pictures
  /// with. Only a text model is ever the active one.
  var kind: ModelKind = .text

  var id: URL { url }
  var fileName: String { url.lastPathComponent }
}

/// The models on the phone, and which one the chat runs on.
///
/// Several can be installed at once — the catalog model beside an imported one — and one is active. Downloads
/// go into Application Support/Models, which is hidden from the Files app and excluded from
/// backups; the active one is remembered by name, so it survives a relaunch and a reinstall.
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
  /// Every model on the phone, by name. The one in `state` is the one in use.
  private(set) var installed: [ModelFile] = []
  /// The downloads under way or just failed, by catalog id. Several at once is fine: each has its
  /// own file, its own record of how far it got, and its own transfers. A finished one is dropped
  /// from here; a failed one stays until it is tried again or started over, so its row can say why.
  private(set) var downloads: [String: ModelDownloader] = [:]

  /// Downloading several gigabytes over a cellular plan is rarely what someone wants, so it's off
  /// until they say otherwise. One switch for every download.
  var allowsCellular = ModelDownloader.allowsCellular {
    didSet { ModelDownloader.allowsCellular = allowsCellular }
  }

  /// Whether Anvil Pro is active, as the root view hears it from the App Store. A Pro model on the
  /// phone stays listed whatever this says, but is only ever the active one while it is true: when
  /// Pro lapses the chat moves to a free model, or to the install screen if there is none.
  var proUnlocked = false {
    didSet { if proUnlocked != oldValue { apply(installed) } }
  }

  private var isRefreshing = false
  private var installTasks: [String: Task<Void, Never>] = [:]

  /// Downloads the app closing interrupted, each of which can be carried on. Not the ones already
  /// carrying on.
  var interruptedDownloads: [CatalogModel] {
    ModelDownloader.interrupted.filter { !(downloads[$0.id]?.isActive ?? false) }
  }

  /// The download of `model`, while it is under way or has just failed.
  func downloader(for model: CatalogModel) -> ModelDownloader? { downloads[model.id] }

  /// Whether any download is under way.
  var isDownloading: Bool { downloads.values.contains { $0.isActive } }

  var active: ModelFile? {
    if case .ready(let file) = state { return file }
    return nil
  }

  /// The image model the chat can make pictures with: Anvil Dream, while it is installed and Pro
  /// is active. It is never the active model; it works beside whichever text model is.
  var imageModel: ModelFile? {
    installed.first { $0.kind == .image && usable($0) }
  }

  /// Downloads a model from anvilai.com. Whatever is already installed stays; the new one joins it.
  /// Why the last install didn't start: not enough room on the phone. The screens put it in an
  /// alert and clear it when the alert is dismissed.
  var storageWarning: String?

  func install(_ model: CatalogModel) {
    guard !(downloads[model.id]?.isActive ?? false), !model.isComingSoon else { return }
    // Room is checked before anything starts, so a phone that is nearly full hears about it in a
    // sentence rather than watching a download begin and stop. What the other downloads under way
    // still need is counted too: they will want their room before this one has finished.
    let resumeFrom = min(ModelDownloadFiles.loadState(for: model.id)?.nextPart ?? 0, model.parts.count)
    let reserved = downloads.values.filter(\.isActive).reduce(Int64(0)) { $0 + $1.remainingBytes }
    if let short = ModelDownloadFiles.storageShortfall(for: model, from: resumeFrom, reserving: reserved) {
      storageWarning = ModelDownloadFiles.storageMessage(
        for: model.name, needed: short.needed, free: short.free)
      return
    }
    installTasks[model.id]?.cancel()
    let downloader = ModelDownloader()
    downloader.reservedElsewhere = reserved
    downloads[model.id] = downloader
    installTasks[model.id] = Task { [self] in
      await downloader.run(model)
      installTasks[model.id] = nil
      if downloader.phase == .finished {
        downloads[model.id] = nil
        await refresh()
      }
    }
  }

  /// Stops the download of `model` and throws away what it had. For someone cancelling on purpose.
  func cancelInstall(_ model: CatalogModel) async {
    installTasks[model.id]?.cancel()
    _ = await installTasks[model.id]?.value
    installTasks[model.id] = nil
    if let downloader = downloads[model.id] {
      downloader.discard(model)
    } else {
      ModelDownloadFiles.discard(model)
    }
    downloads[model.id] = nil
  }

  func refresh() async {
    // Only finished models are listed — a file still being built has another extension — so a
    // download under way is no reason not to look.
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      let files = try ModelFiles.models(in: ModelFiles.modelsDirectory()).map(ModelFiles.describe)
      apply(files)
    } catch {
      setState(.failed(error.localizedDescription))
    }
  }

  /// Makes this the model the chat runs on. The chat sees the change and loads it.
  func select(_ file: ModelFile) {
    guard installed.contains(file), usable(file), file.kind == .text else { return }
    ModelFiles.setActiveFileName(file.fileName)
    setState(.ready(file))
  }

  /// Deletes one model. If it was the one in use, whichever is left takes over — or nothing does.
  func remove(_ file: ModelFile) async {
    do {
      try await Task.detached { try ModelFiles.remove(file) }.value
      if ModelFiles.activeFileName() == file.fileName { ModelFiles.setActiveFileName(nil) }
      apply(installed.filter { $0 != file })
    } catch {
      setState(.failed(error.localizedDescription))
    }
  }

  /// Settles on what is installed and which of it is active: the one chosen before if it is still
  /// here and can be used, else the one already in use, else the default. What is written down is
  /// the choice, not the fallback: a Pro model chosen and then merely unusable for the moment —
  /// the App Store not yet asked at launch, or Pro lapsed — stays the choice, and is what the chat
  /// comes back to when Pro is confirmed. It used to be overwritten by the default on the first
  /// refresh of every launch, before the App Store had answered, so a chosen model kept turning
  /// back into Anvil Core. Only a file that is gone from the phone loses its place.
  private func apply(_ files: [ModelFile]) {
    installed = files
    let candidates = files.filter { $0.kind == .text && usable($0) }
    guard let first = candidates.first else {
      setState(.missing)
      return
    }
    // The default is Anvil Core, the model the catalog recommends: it is what a new install runs
    // on, and what the chat comes back to when a Pro model can't be used any more. Failing that,
    // any free model from the catalog, before a file that was imported by hand.
    let fallback =
      candidates.first { $0.isRecommended }
      ?? candidates.first { !$0.isPro && $0.catalogID != nil }
      ?? first
    let remembered = ModelFiles.activeFileName()
    let chosen =
      candidates.first { $0.fileName == remembered }
      ?? candidates.first { $0.fileName == active?.fileName }
      ?? fallback
    let rememberedStillHere = files.contains { $0.kind == .text && $0.fileName == remembered }
    if chosen.fileName == remembered || !rememberedStillHere {
      ModelFiles.setActiveFileName(chosen.fileName)
    }
    setState(.ready(chosen))
  }

  /// Free models always; a Pro model only while Pro is active.
  private func usable(_ file: ModelFile) -> Bool {
    proUnlocked || !file.isPro
  }

  private func setState(_ newState: State) {
    if state != newState { state = newState }
  }
}

/// The file-system side of installing a model. Not tied to an actor, so the slow parts can run off
/// the main thread.
enum ModelFiles {
  static let fileExtension = "litertlm"
  /// An image model is a folder — the compiled Core ML models Anvil Dream runs — and is told
  /// apart from a text model by this extension on the folder.
  static let imageModelExtension = "imagemodel"
  private static let activeFileNameKey = "activeModelFileName"

  /// The folder an image model is unpacked into, named for its catalog id.
  static func imageModelName(for id: String) -> String {
    id + "." + imageModelExtension
  }

  /// Where the models live: private to the app and never backed up.
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

  /// Every model in the directory, by name: text model files, and image model folders.
  static func models(in directory: URL) throws -> [URL] {
    try FileManager.default
      .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      .filter {
        let ext = $0.pathExtension.lowercased()
        return ext == fileExtension || ext == imageModelExtension
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Everything in a folder, added up: an image model's size is the size of what was unpacked.
  static func directorySize(of url: URL) -> Int64 {
    guard
      let files = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
    else { return 0 }
    var total: Int64 = 0
    for case let file as URL in files {
      total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
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
    let record = ModelDownloadFiles.installed(named: url.lastPathComponent)
    let isImage = url.pathExtension.lowercased() == imageModelExtension
    return ModelFile(
      url: url,
      fileSize: isImage
        ? directorySize(of: url) : (attributes[.size] as? NSNumber)?.int64Value ?? 0,
      modificationDate: attributes[.modificationDate] as? Date ?? .distantPast,
      displayName: record?.name ?? url.deletingPathExtension().lastPathComponent,
      catalogID: record?.id,
      version: record?.version,
      isPro: record?.pro ?? false,
      isRecommended: record?.recommended ?? false,
      kind: isImage ? .image : .text)
  }

  /// The file, and the record of what it was.
  static func remove(_ file: ModelFile) throws {
    try FileManager.default.removeItem(at: file.url)
    ModelDownloadFiles.forget(file.fileName)
  }

  static func activeFileName() -> String? {
    UserDefaults.standard.string(forKey: activeFileNameKey)
  }

  static func setActiveFileName(_ name: String?) {
    UserDefaults.standard.set(name, forKey: activeFileNameKey)
  }

  private static func excludeFromBackup(_ url: inout URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
}
