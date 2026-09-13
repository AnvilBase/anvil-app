import Foundation

/// Reads what LiteRT-LM says while an engine is being created.
///
/// When the engine can't be created, the C API returns null and the Swift wrapper throws "Failed
/// to create engine." with nothing after it. The reason — "INVALID_ARGUMENT: Unsupported file
/// format", "RESOURCE_EXHAUSTED: ...", a Metal compiler complaint — is written by the runtime to
/// the process's standard error and nowhere else. So for the length of a load, standard error is
/// routed through a pipe: every byte still reaches its original destination (the Xcode console),
/// and the error lines are kept to be shown on the failure screen.
///
/// One capture at a time, which `OnDeviceEngine` guarantees by being an actor.
final class EngineLog {
  private let pipe = Pipe()
  private let original: Int32
  private let drained = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var text = ""

  /// Starts routing standard error through the capture. Nil when the descriptors can't be set up,
  /// in which case the load simply runs without it.
  init?() {
    original = dup(STDERR_FILENO)
    guard original >= 0 else { return nil }
    guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0 else {
      close(original)
      return nil
    }
    let reader = pipe.fileHandleForReading
    let forwardTo = original
    DispatchQueue.global(qos: .utility).async { [weak self] in
      while true {
        let data = reader.availableData
        if data.isEmpty { break }
        data.withUnsafeBytes { bytes in
          var offset = 0
          while offset < bytes.count {
            let written = write(forwardTo, bytes.baseAddress! + offset, bytes.count - offset)
            if written <= 0 { break }
            offset += written
          }
        }
        guard let self else { continue }
        self.lock.lock()
        self.text += String(decoding: data, as: UTF8.self)
        self.lock.unlock()
      }
      self?.drained.signal()
    }
  }

  /// Puts standard error back and returns the error lines the runtime wrote, oldest first, with
  /// the log prefix (severity, time, thread, source file) taken off.
  func finish() -> [String] {
    dup2(original, STDERR_FILENO)
    close(original)
    try? pipe.fileHandleForWriting.close()
    _ = drained.wait(timeout: .now() + 1)
    try? pipe.fileHandleForReading.close()
    lock.lock()
    defer { lock.unlock() }
    return Self.errorLines(in: text)
  }

  /// The runtime's own reason for a failed load, or nil when it said nothing.
  ///
  /// The last line is the one that names the failure ("Failed to create engine: INTERNAL: ...");
  /// what comes before it is the executor explaining itself on the way down. The status is kept,
  /// and the one distinct line before it when there is one, since that's usually the specific
  /// message the status wraps.
  static func reason(from lines: [String]) -> String? {
    guard let last = lines.last else { return nil }
    let status = last.replacingOccurrences(
      of: #"^Failed to create (engine|session|conversation): "#, with: "",
      options: .regularExpression)
    let earlier = lines.dropLast().last { !$0.isEmpty && !status.contains($0) && !$0.contains(status) }
    return [earlier, status].compactMap { $0 }.joined(separator: " — ")
  }

  /// A sentence on what to do about it, when the reason points somewhere clear.
  static func advice(for reason: String) -> String? {
    let lower = reason.lowercased()
    if lower.contains("resource_exhausted") || lower.contains("memory")
      || lower.contains("bad_alloc") || lower.contains("allocat")
    {
      return "Turn off image input or choose a smaller context in Settings › Models."
    }
    if lower.contains("unsupported") || lower.contains("parse") || lower.contains("invalid")
      || lower.contains("not_found") || lower.contains("format") || lower.contains("magic")
      || lower.contains("section")
    {
      return "Delete the model in Settings › Model and download it again."
    }
    return nil
  }

  /// Error and fatal lines in absl's log format, "E0913 02:58:00.123456 12345 engine.cc:800] …",
  /// plus any other line that says something failed (Metal writes its complaints without the
  /// prefix). Duplicates are dropped.
  static func errorLines(in text: String) -> [String] {
    var seen = Set<String>()
    var lines: [String] = []
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      var message: String?
      if let range = line.range(of: #"^[EF]\d{4} \S+ +\d+ [^\]]*\] "#, options: .regularExpression) {
        message = String(line[range.upperBound...])
      } else if line.range(of: #"^[IWV]\d{4} "#, options: .regularExpression) == nil {
        let lower = line.lowercased()
        if lower.contains("fail") || lower.contains("error") { message = line }
      }
      if let message, !message.isEmpty, seen.insert(message).inserted { lines.append(message) }
    }
    return lines
  }
}
