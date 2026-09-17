import Foundation

/// Fetches model parts in a background URLSession.
///
/// A model is several gigabytes. A background session keeps the transfer going while the app is in
/// the background, and finishes it even if the app is closed — iOS hands the file over the next time
/// the app runs.
final class ModelDownloadSession: NSObject {
  static let shared = ModelDownloadSession()

  /// Background sessions are identified by name rather than by object: the same name has to come
  /// back after a relaunch for iOS to deliver what it finished while the app was away. It includes
  /// the bundle identifier so the public and development apps never share a session.
  static let identifier = AppFlavor.storageNamespace + ".model-download"

  enum Failure: LocalizedError {
    case http(Int)
    case unnamed

    var errorDescription: String? {
      switch self {
      case .http(let code): "The download answered with \(code)."
      case .unnamed: "A download finished without a file name."
      }
    }
  }

  private struct Pending {
    let progress: (Int64, Int64) -> Void
    let finish: (Result<URL, Error>) -> Void
  }

  private let lock = NSLock()
  private var pending: [Int: Pending] = [:]
  private var names: [Int: String] = [:]
  private var lastProgress: [Int: Date] = [:]
  private var backgroundEventsFinished: (() -> Void)?

  /// iOS reports written bytes far more often than a progress bar can use. Reporting every one of
  /// them buries the main actor in work and the number stops moving, which reads as a stuck
  /// download while the bytes are in fact still landing.
  private static let progressInterval: TimeInterval = 0.1

  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    configuration.sessionSendsLaunchEvents = true
    // Someone is watching a progress bar; don't let iOS wait for a better moment.
    configuration.isDiscretionary = false
    // Every part of a model is handed over at once, so that iOS carries the whole thing down while
    // the app is away rather than the app having to be there to ask for the next one. This is what
    // decides how many of them actually run together — the parts past it queue here rather than
    // being left unasked for, which is the difference between a download that survives the app
    // going away and one that doesn't.
    configuration.httpMaximumConnectionsPerHost = 8
    configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }()

  /// Building the session is what makes iOS deliver transfers that finished while the app wasn't
  /// running, so this is called on launch as well as before a download starts.
  func activate() { _ = session }

  /// Downloads one part and returns where it was staged. Cancelling the surrounding task cancels the
  /// transfer.
  func download(
    _ part: CatalogPart,
    allowsCellular: Bool,
    onProgress: @escaping (Int64, Int64) -> Void
  ) async throws -> URL {
    // A part that arrived while the app was closed is already on disk.
    if let staged = ModelDownloadFiles.stagedPart(part) { return staged }

    var request = URLRequest(url: part.url)
    request.allowsCellularAccess = allowsCellular
    request.allowsExpensiveNetworkAccess = allowsCellular
    let task = session.downloadTask(with: request)

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        names[task.taskIdentifier] = part.name
        pending[task.taskIdentifier] = Pending(progress: onProgress) { result in
          continuation.resume(with: result)
        }
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  func cancelAll() {
    session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
  }

  /// Called from the scene's background handler: iOS gives the app a moment to take delivery of
  /// downloads that finished while it wasn't running.
  func handleBackgroundEvents() async {
    activate()
    await withCheckedContinuation { continuation in
      lock.lock()
      backgroundEventsFinished = { continuation.resume() }
      lock.unlock()
      // Don't hold the app awake if nothing was waiting.
      DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
        self?.finishBackgroundEvents()
      }
    }
  }

  private func finishBackgroundEvents() {
    lock.lock()
    let handler = backgroundEventsFinished
    backgroundEventsFinished = nil
    lock.unlock()
    handler?()
  }

  private func finish(_ taskIdentifier: Int, with result: Result<URL, Error>) {
    lock.lock()
    let handler = pending.removeValue(forKey: taskIdentifier)
    names.removeValue(forKey: taskIdentifier)
    lastProgress.removeValue(forKey: taskIdentifier)
    lock.unlock()
    handler?.finish(result)
  }
}

extension ModelDownloadSession: URLSessionDownloadDelegate {
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
  ) {
    do {
      if let http = downloadTask.response as? HTTPURLResponse,
        !(200..<300).contains(http.statusCode)
      {
        throw Failure.http(http.statusCode)
      }
      lock.lock()
      let registered = names[downloadTask.taskIdentifier]
      lock.unlock()
      // After a relaunch nothing is registered, but the part name is still in the request URL.
      guard let name = registered ?? downloadTask.originalRequest?.url?.lastPathComponent,
        !name.isEmpty
      else { throw Failure.unnamed }

      // iOS deletes the file at `location` as soon as this returns, so move it now.
      let staged = try ModelDownloadFiles.stage(location, as: name)
      finish(downloadTask.taskIdentifier, with: .success(staged))
    } catch {
      finish(downloadTask.taskIdentifier, with: .failure(error))
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    let now = Date()
    lock.lock()
    let progress = pending[downloadTask.taskIdentifier]?.progress
    let last = lastProgress[downloadTask.taskIdentifier]
    // Always report the final byte, so a part never appears to stop short of its size.
    let isDue =
      last.map { now.timeIntervalSince($0) >= Self.progressInterval } ?? true
      || (totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite)
    if isDue { lastProgress[downloadTask.taskIdentifier] = now }
    lock.unlock()
    guard isDue else { return }
    progress?(totalBytesWritten, totalBytesExpectedToWrite)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    // Success was already reported when the file was staged.
    guard let error else { return }
    finish(task.taskIdentifier, with: .failure(error))
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    finishBackgroundEvents()
  }
}
