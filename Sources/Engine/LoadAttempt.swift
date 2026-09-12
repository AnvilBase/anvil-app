import Foundation

/// A note left on disk while the engine loads, so the app can tell that a configuration killed it.
///
/// Running out of memory here isn't a Swift error and can't be caught: the allocator throws a C++
/// `std::bad_alloc` and the process aborts, taking any `catch` block with it. The engine's own
/// fallbacks only help for failures it survives. So the only evidence that a configuration is too
/// big for this phone is finding its note still on disk at the next launch — and without that, the
/// app relaunches into the same load and dies again, with no way to reach Settings in between.
enum LoadAttempt {
  private static let fileName = "load-attempt.json"

  private static var url: URL? {
    guard
      let support = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    return support.appendingPathComponent(fileName)
  }

  /// Records what is about to be tried. Written synchronously: whatever isn't on disk before the
  /// load starts isn't there after the process dies.
  static func begin(_ options: EngineOptions) {
    guard let url, let data = try? JSONEncoder().encode(options) else { return }
    try? data.write(to: url, options: .atomic)
  }

  static func succeeded() {
    guard let url else { return }
    try? FileManager.default.removeItem(at: url)
  }

  /// The configuration that was being loaded when the app last died, if it did.
  static func abandoned() -> EngineOptions? {
    guard let url, let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(EngineOptions.self, from: data)
  }
}

extension EngineOptions {
  /// The next thing worth trying after this configuration proved too big, or nil when there's
  /// nothing left to give up. Ordered by how much memory each one frees: the vision encoder is a
  /// block of hundreds of megabytes, the KV cache scales with context, and the GPU path holds
  /// weights that the CPU path memory-maps instead.
  func afterRunningOutOfMemory() -> EngineOptions? {
    if imageInput {
      var reduced = self
      reduced.imageInput = false
      return reduced
    }
    if let smaller = AppSettings.contextSizes.last(where: { $0 < contextSize }) {
      var reduced = self
      reduced.contextSize = smaller
      return reduced
    }
    if backend != .cpu {
      var reduced = self
      reduced.backend = .cpu
      return reduced
    }
    return nil
  }

  /// What changed, in the words the setting uses, for telling the user why.
  func differences(from original: EngineOptions) -> [String] {
    var changes: [String] = []
    if imageInput != original.imageInput, !imageInput { changes.append("image input is off") }
    if contextSize != original.contextSize { changes.append("context is \(contextSize)") }
    if backend != original.backend { changes.append("it's running on the \(backend.rawValue)") }
    return changes
  }
}
