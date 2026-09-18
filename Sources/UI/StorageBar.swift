import SwiftUI

/// What a model will cost this phone, drawn before anyone presses Download.
///
/// A number on its own — "4.17 GB" — says what the model is but not whether this phone
/// can take it, which is the only question being asked at that moment. The bar answers
/// it: what is already used, what this model would add, and whether what is left after
/// it is enough for the phone to go on working normally.
///
/// Green or red, and nothing in between. There is one decision here and the colour is
/// it, so a glance is the whole reading.
struct StorageBar: View {
  /// The bytes the middle band stands for: what a download would add, or — when
  /// `isProposed` is false — what the models on the phone already take.
  let needed: Int64
  /// What the phone has free right now, or nil when it won't say.
  let free: Int64?
  /// Everything the phone holds, used and free, or nil when it won't say.
  let capacity: Int64?
  /// Whether the middle band is something being weighed up or something already there.
  /// A download asks whether it fits and is answered in green or red; what is installed
  /// isn't a question, so it is drawn plainly and says what it takes.
  var isProposed: Bool = true
  /// What the download gives back before it takes anything: Anvil Core's space, when
  /// Anvil Pro is what is being weighed. Counted as free, because by the time the first
  /// byte lands it will be — Core goes first — and the room shown is the room there is.
  var reclaimed: Int64 = 0

  /// What is free once the download has given back what it will.
  private var effectiveFree: Int64? { free.map { $0 + reclaimed } }

  /// Room to leave over once the model is in. A phone with a few megabytes spare is a
  /// phone that stutters, warns, and eventually can't take a photo — so the answer to
  /// "does it fit" is not "yes, exactly", it is "yes, with room to live in".
  ///
  /// The downloader's own number, not a second one: what this draws in red is exactly
  /// what `ModelDownloadFiles.storageShortfall` will refuse to start.
  static var buffer: Int64 { ModelDownloadFiles.storageBuffer }

  /// Whether there is room for the model and the room to spare after it.
  var fits: Bool {
    guard isProposed, let free = effectiveFree else { return true }
    return free - needed >= Self.buffer
  }

  private var tint: Color { isProposed ? (fits ? .green : .red) : .secondary }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      bar
      HStack(spacing: 4) {
        Image(systemName: fits ? "internaldrive" : "exclamationmark.triangle.fill")
          .accessibilityHidden(true)
          .font(.caption2)
          .foregroundStyle(fits ? Color.secondary : tint)
        Text(caption)
          .font(.caption)
          .foregroundStyle(fits ? Color.secondary : tint)
      }
      .accessibilityElement(children: .combine)
    }
  }

  /// Three bands in one line: what the phone already holds, what this would add, and
  /// what would be left. The middle one is the model, in the colour that says whether
  /// it can go there at all.
  private var bar: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      HStack(spacing: 1) {
        Rectangle()
          .fill(Color.secondary.opacity(0.35))
          .frame(width: width * fraction(of: used))
        Rectangle()
          .fill(tint)
          .frame(width: width * fraction(of: needed))
        Rectangle()
          .fill(Color.secondary.opacity(0.12))
      }
      .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    .frame(height: 6)
  }

  /// The first band: what the phone holds that isn't the middle band. For a download
  /// that is everything already on the phone; for what is installed it is everything
  /// else, so the models' share reads as its own slice rather than as part of the rest.
  private var used: Int64 {
    guard let capacity, let free = effectiveFree else { return 0 }
    let occupied = max(capacity - free, 0)
    return isProposed ? occupied : max(occupied - needed, 0)
  }

  /// A band's share of the bar. Without a capacity to divide by there is nothing to
  /// draw, and the bar stays empty rather than inventing a proportion.
  private func fraction(of bytes: Int64) -> Double {
    guard let capacity, capacity > 0 else { return 0 }
    return min(max(Double(bytes) / Double(capacity), 0), 1)
  }

  private var caption: String {
    if !isProposed {
      guard let free, let capacity else { return "\(Self.format(needed)) of models" }
      return "\(Self.format(needed)) of models · \(Self.format(free)) free of \(Self.format(capacity))"
    }
    guard let free = effectiveFree else { return "\(Self.format(needed)) to download" }
    if fits {
      return "\(Self.format(needed)) to download · \(Self.format(free - needed)) free afterwards"
    }
    // What is missing, said as the number to go and free up, because that is the thing
    // to act on. The buffer is part of it: it is needed, so it is counted.
    let short = Self.buffer - (free - needed)
    return "Needs \(Self.format(short)) more space · \(Self.format(free)) free"
  }

  static func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
  }
}

/// What the phone has, read fresh. `URL` caches resource values, which would keep
/// answering with the space there was before a download rather than the space there is.
enum DeviceStorage {
  static func free() -> Int64? { ModelDownloadFiles.freeBytes() }

  static func capacity() -> Int64? {
    guard let models = try? ModelFiles.modelsDirectory(),
      let values = try? models.resourceValues(forKeys: [.volumeTotalCapacityKey]),
      let total = values.volumeTotalCapacity
    else { return nil }
    return Int64(total)
  }
}
