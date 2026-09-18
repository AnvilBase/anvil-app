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
  /// For an image model, what the folder should add up to, from the install record. Nil for a
  /// record that predates it, in which case the folder is checked file by file only.
  var expectedBytes: Int64? = nil
  /// A text model, which the chat runs on, or an image model, which Anvil Dream makes pictures
  /// with. Only a text model is ever the active one.
  var kind: ModelKind = .text

  var id: URL { url }
  var fileName: String { url.lastPathComponent }

  /// What the model answers to, which is what the app calls it: the name the catalog publishes
  /// it under, the same one its card and its row wear.
  var spokenName: String { displayName }
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
  /// The plan installs under way, by plan id. A plan's files are fetched one after another, so
  /// this is the task walking the plan rather than any one download.
  private var planTasks: [String: Task<Void, Never>] = [:]

  /// Downloads the app closing interrupted, each of which can be carried on. Not the ones already
  /// carrying on.
  var interruptedDownloads: [CatalogModel] {
    ModelDownloader.interrupted.filter { !(downloads[$0.id]?.isActive ?? false) }
  }

  /// The download of `model`, while it is under way or has just failed.
  func downloader(for model: CatalogModel) -> ModelDownloader? { downloads[model.id] }

  /// Whether this catalog model is already on the phone.
  func isInstalled(_ model: CatalogModel) -> Bool {
    installed.contains { $0.catalogID == model.id || $0.fileName == model.fileName }
  }

  // MARK: - Plans

  /// Whether the whole of a plan is on the phone. Anvil Pro is two files, and half of it isn't it.
  func isInstalled(_ plan: ModelPlan) -> Bool {
    !plan.publishedModels.isEmpty && plan.publishedModels.allSatisfy { isInstalled($0) }
  }

  /// The plan's files that are here, for the rows that list or delete them.
  func installedFiles(of plan: ModelPlan) -> [ModelFile] {
    installed.filter { file in
      plan.models.contains { $0.id == file.catalogID || $0.fileName == file.fileName }
    }
  }

  /// Whether the chat is running on this plan's model.
  func isActive(_ plan: ModelPlan) -> Bool {
    guard let active else { return false }
    return installedFiles(of: plan).contains(active)
  }

  /// The catalog has something newer for a file of this plan that is on the phone.
  func hasUpdate(for plan: ModelPlan) -> Bool {
    plan.publishedModels.contains { model in
      installed.contains { $0.catalogID == model.id && $0.version != model.version }
    }
  }

  /// The download this plan has going, or the one that stopped: the plan's files arrive one at a
  /// time, so at most one of them is ever the one to show.
  func downloader(for plan: ModelPlan) -> ModelDownloader? {
    let planDownloads = plan.models.compactMap { downloads[$0.id] }
    return planDownloads.first { $0.isActive } ?? planDownloads.first
  }

  /// Whether a plan has a download the app closed part-way through, waiting to be carried on.
  func isInterrupted(_ plan: ModelPlan) -> Bool {
    let carryingOn = plan.models.contains { downloads[$0.id]?.isActive ?? false }
    return !carryingOn && interruptedDownloads.contains { plan.contains($0) }
  }

  /// How far the whole plan is: what is already here, plus how far the file in hand has got, over
  /// everything the plan is. Nil until one of its files is on the way, because a percentage of
  /// nothing means nothing.
  func progress(of plan: ModelPlan) -> (received: Int64, total: Int64, fraction: Double)? {
    let models = plan.publishedModels
    guard models.contains(where: { downloads[$0.id] != nil }) else { return nil }
    var received: Int64 = 0
    var total: Int64 = 0
    for model in models {
      total += model.sizeBytes
      if isInstalled(model) {
        received += model.sizeBytes
      } else if let downloader = downloads[model.id] {
        received += downloader.receivedBytes
      }
    }
    guard total > 0 else { return nil }
    return (received, total, min(Double(received) / Double(total), 1))
  }

  /// Which of the plan's files is in hand, and what is being done with it. One bar for Anvil Pro
  /// counts its two files as one thing, and this is the line under it that says which of the two
  /// is coming down right now, and whether it is being fetched, checked or unpacked.
  struct Stage: Equatable {
    let model: CatalogModel
    /// Which file this is of how many: 1 of 2.
    let position: Int
    let count: Int
    let phase: ModelDownloader.Phase

    /// A word for the moment the bar can't show: "Checking…" while a part is hashed,
    /// "Unpacking…" while a picture model's archive is expanded. Nil while bytes are simply
    /// arriving — the bar already says that, and a line repeating it is a line too many.
    var note: String? {
      switch phase {
      case .checking: "Checking…"
      case .installing: model.isImage ? "Unpacking…" : "Installing…"
      case .downloading, .idle, .finished, .failed: nil
      }
    }
  }

  /// The file of the plan on its way, if one is: the plan's files arrive one at a time.
  func stage(of plan: ModelPlan) -> Stage? {
    let models = plan.publishedModels
    guard let index = models.firstIndex(where: { downloads[$0.id]?.isActive ?? false }),
      let downloader = downloads[models[index].id]
    else { return nil }
    return Stage(
      model: models[index], position: index + 1, count: models.count, phase: downloader.phase)
  }

  /// What the plan still costs in space: the files of it that aren't on the phone yet. Half of
  /// Anvil Pro already down is half of Anvil Pro left to fetch, and the row that offers it should
  /// say the number that pressing it will actually cost.
  func remainingSize(of plan: ModelPlan) -> Int64 {
    plan.publishedModels.filter { !isInstalled($0) }.reduce(0) { $0 + $1.sizeBytes }
  }

  /// What the plan will hold on the phone once it is in: a chat model is its file, a picture
  /// model is the folder its archive unpacks to.
  func keptBytes(of plan: ModelPlan) -> Int64 {
    plan.publishedModels.filter { !isInstalled($0) }.reduce(0) {
      $0 + ($1.isImage ? ($1.unpackedBytes ?? $1.sizeBytes) : $1.sizeBytes)
    }
  }

  /// What the plan needs at its fullest moment, which is more than it keeps. A picture model
  /// arrives as an archive and is unpacked beside it — both on disk at once until the unpacking
  /// is done and the archive goes — and by then every model before it in the plan is already
  /// down. This is the number a download has to be measured against before it starts: the bar
  /// said Anvil Pro fit and the download said it didn't, because the bar counted what Pro
  /// keeps and the download met the moment it needs the most.
  func peakBytes(of plan: ModelPlan) -> Int64 {
    plan.publishedModels.filter { !isInstalled($0) }.reduce(0) {
      $0 + $1.sizeBytes + ($1.isImage ? ($1.unpackedBytes ?? $1.sizeBytes) : 0)
    }
  }

  /// Why the plan can't start: what it needs free — its fullest moment plus the room to spare
  /// after — against what the phone has. Nil when it fits. One answer, asked before anything is
  /// fetched, and the same one the bar on the screen draws.
  func storageShortfall(for plan: ModelPlan) -> (needed: Int64, free: Int64)? {
    guard let free = ModelDownloadFiles.freeBytes() else { return nil }
    let needed = peakBytes(of: plan) + ModelDownloadFiles.storageBuffer
    return free < needed ? (needed, free) : nil
  }

  /// Downloads what the plan is missing. Nothing else is touched: a model joins whatever is on
  /// the phone, and what goes is what someone swipes away. A download that stops leaves Try
  /// again to carry on from what is already down rather than start over.
  func install(_ plan: ModelPlan) {
    guard planTasks[plan.id] == nil, purchasable(plan) else { return }
    // Room for it, decided before a byte is fetched.
    if let short = storageShortfall(for: plan) {
      storageWarning = ModelDownloadFiles.storageMessage(
        for: plan.name, needed: short.needed, free: short.free)
      return
    }
    downloadingPlan = plan
    planTasks[plan.id] = Task { [self] in
      defer {
        planTasks[plan.id] = nil
        if downloadingPlan?.id == plan.id { downloadingPlan = nil }
      }
      for model in plan.publishedModels where !isInstalled(model) {
        install(model)
        while let task = installTasks[model.id] { _ = await task.value }
        guard isInstalled(model) else { return }
      }
    }
  }

  /// Whichever plan is being installed, for the chat to name and measure what is arriving. Nil
  /// when nothing is.
  private(set) var downloadingPlan: ModelPlan?

  /// Stops whatever the plan has going and throws away what it had. What is already installed
  /// stays installed: this is cancelling a download, not deleting a model.
  func cancelInstall(_ plan: ModelPlan) async {
    planTasks[plan.id]?.cancel()
    planTasks[plan.id] = nil
    for model in plan.models where !isInstalled(model) {
      await cancelInstall(model)
    }
  }

  /// Deletes the whole plan. Anvil Pro is one thing on screen, so it is one thing to delete.
  func remove(_ plan: ModelPlan) async {
    for file in installedFiles(of: plan) {
      await remove(file)
    }
  }

  /// Makes the chat run on this plan's model.
  func select(_ plan: ModelPlan) {
    guard let file = installedFiles(of: plan).first(where: { $0.kind == .text }) else { return }
    select(file)
  }

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

  /// Whether a model to chat with — Anvil Core or Anvil Raw — is on the phone. Anvil Dream only
  /// makes pictures for a chat, so it waits for one of them: the screens say so, and this refuses.
  var hasTextModel: Bool { installed.contains { $0.kind == .text } }

  func install(_ model: CatalogModel) {
    guard !(downloads[model.id]?.isActive ?? false), !model.isComingSoon else { return }
    guard proUnlocked || !model.isPro else { return }
    guard !model.isImage || hasTextModel else { return }
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
  ///
  /// The row goes back to what it was before anything is waited for: the downloader leaves the
  /// list, and its transfers are cut, in the same turn as the press. It used to cancel the task
  /// and wait for it, and the task was waiting on the part in hand — hundreds of megabytes that
  /// cancelling the task didn't reach — so Cancel looked ignored until that part had landed.
  /// The files are thrown away once the task has actually stopped, so nothing it was still
  /// writing comes back as a download to resume.
  func cancelInstall(_ model: CatalogModel) async {
    let task = installTasks[model.id]
    let downloader = downloads[model.id]
    task?.cancel()
    downloads[model.id] = nil
    downloader?.stop()
    _ = await task?.value
    if installTasks[model.id] == task { installTasks[model.id] = nil }
    // Unless Download was pressed again in the meantime: then the parts on disk are the new
    // download's, and it is appending to them.
    if downloads[model.id] == nil { ModelDownloadFiles.discard(model) }
  }

  /// Carries on a download the app didn't get to finish: iOS closed the app while it was away, or
  /// it was killed for the memory. The staged parts are still on disk and the file being built is a
  /// correct prefix of the model, so this picks up where it stopped rather than starting over.
  ///
  /// Calls each installed model what the catalog calls it now. The name is written down when
  /// a model is downloaded, and the catalog can rename one afterwards — Anvil Raw became Anvil
  /// Pro — so whenever the catalog is read, the records are brought into line and the files
  /// read again. A renamed model reads as a different file to the chat, which reloads it once.
  func adoptNames(from catalog: [CatalogModel]) async {
    var changed = false
    for model in catalog
    where installed.contains(where: { $0.catalogID == model.id && $0.displayName != model.name }) {
      changed = ModelDownloadFiles.rename(id: model.id, to: model.name) || changed
    }
    if changed { await refresh() }
  }

  func refresh() async {
    // Only finished models are listed — a file still being built has another extension — so a
    // download under way is no reason not to look.
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      let found = try ModelFiles.models(in: ModelFiles.modelsDirectory()).map(ModelFiles.describe)
      var files: [ModelFile] = []
      for file in found {
        // A picture model folder with only part of a model in it, left by an unpacking that was
        // interrupted back when unpacking wrote straight into place. It reads as installed, so the
        // app offers pictures and the first one asked for fails on a file that was never written.
        // It goes: what the app says it has should be what it has. A download still part-way
        // through waits behind Resume, which unpacks it again from the archive if that is still on
        // the phone; otherwise the image model is offered for download again.
        if file.kind == .image, !ImageArchive.isComplete(file.url, unpackedBytes: file.expectedBytes) {
          try? await Task.detached { try ModelFiles.remove(file) }.value
          continue
        }
        files.append(file)
      }
      apply(files)
      // Whatever is cached for a model that isn't here goes with it.
      let kept = files
      Task.detached(priority: .utility) { ModelFiles.pruneCaches(keeping: kept) }
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
      let kept = installed
      Task.detached(priority: .utility) { ModelFiles.pruneCaches(keeping: kept) }
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

  /// Whether a plan may be fetched at all. The screens already show a Pro plan's card as a way to
  /// the paywall rather than a Download, so this is the floor under that rather than the thing the
  /// reader sees: Pro's files don't come down the wire without a subscription, whichever button
  /// asked for them and whether or not a download was under way when Pro lapsed.
  private func purchasable(_ plan: ModelPlan) -> Bool {
    proUnlocked || !plan.isPro
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
  ///
  /// Not small. LiteRT-LM writes its packed weights here — `<model>.xnnpack_cache_<id>` — and
  /// that file is about the size of the model: four gigabytes for Anvil Raw, on top of the four
  /// the model is. Core ML keeps its compiled Neural Engine bundles for Anvil Dream in the
  /// Caches folder too, in a folder of its own. iOS counts all of it against the app, so what
  /// Settings › Storage says the app takes is the models plus this, and the "13 GB" that started
  /// it was seven of models and six of cache. Hence `pruneCaches` and `clearCaches`.
  static func cacheDirectory() throws -> URL {
    let caches = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = caches.appendingPathComponent("EngineCache", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Where Core ML keeps what it compiled for the Neural Engine: a folder somewhere under
  /// Caches whose name carries `e5rt`. Looked for rather than known, since where iOS puts it
  /// isn't promised, and one level down is as far as it has ever been.
  private static func coreMLCacheDirectories() -> [URL] {
    guard
      let caches = try? FileManager.default.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    else { return [] }
    let fileManager = FileManager.default
    func entries(of directory: URL) -> [URL] {
      (try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
    }
    var found: [URL] = []
    for entry in entries(of: caches) {
      if entry.lastPathComponent.localizedCaseInsensitiveContains("e5rt") {
        found.append(entry)
      } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        found += entries(of: entry).filter {
          $0.lastPathComponent.localizedCaseInsensitiveContains("e5rt")
        }
      }
    }
    return found
  }

  /// Everything the engines have cached, in bytes: what iOS counts against the app beyond the
  /// models themselves.
  static func cacheBytes() -> Int64 {
    var total: Int64 = 0
    if let engine = try? cacheDirectory() { total += directorySize(of: engine) }
    for directory in coreMLCacheDirectories() { total += directorySize(of: directory) }
    return total
  }

  /// Throws away the caches of models that are no longer on the phone. A cache is named for
  /// its model, so one whose model is gone is weight and nothing else: Anvil Core's four
  /// gigabytes of packed weights were still here after Anvil Pro replaced it. The picture
  /// model's compiled bundles go the same way once no picture model is installed.
  static func pruneCaches(keeping installed: [ModelFile]) {
    let fileManager = FileManager.default
    let textModels = installed.filter { $0.kind == .text }.map(\.fileName)
    if let engine = try? cacheDirectory(),
      let entries = try? fileManager.contentsOfDirectory(at: engine, includingPropertiesForKeys: nil)
    {
      for entry in entries
      where !textModels.contains(where: { entry.lastPathComponent.hasPrefix($0) }) {
        try? fileManager.removeItem(at: entry)
      }
    }
    if !installed.contains(where: { $0.kind == .image }) {
      for directory in coreMLCacheDirectories() { try? fileManager.removeItem(at: directory) }
    }
  }

  /// Throws away every engine cache. The next load of each model rebuilds its own, and takes
  /// longer for it — a minute for a chat model, most of one for the first picture.
  static func clearCaches() {
    let fileManager = FileManager.default
    if let engine = try? cacheDirectory() { try? fileManager.removeItem(at: engine) }
    for directory in coreMLCacheDirectories() { try? fileManager.removeItem(at: directory) }
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
      expectedBytes: record?.unpackedBytes,
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
