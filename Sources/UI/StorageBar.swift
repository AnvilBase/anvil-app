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
  /// The bytes the middle band stands for: what a download needs at its fullest moment, or —
  /// when `isProposed` is false — what the models on the phone already take.
  let needed: Int64
  /// What the download leaves behind once it is done, when that is less than `needed`: a
  /// picture model's archive goes once it is unpacked. Nil means the same as `needed`.
  var keeps: Int64? = nil
  /// What the phone has free right now, or nil when it won't say.
  let free: Int64?
  /// Everything the phone holds, used and free, or nil when it won't say.
  let capacity: Int64?
  /// Whether the middle band is something being weighed up or something already there.
  /// A download asks whether it fits and is answered in green or red; what is installed
  /// isn't a question, so it is drawn plainly and says what it takes.
  var isProposed: Bool = true
  /// Room to leave over once the model is in. A phone with a few megabytes spare is a
  /// phone that stutters, warns, and eventually can't take a photo — so the answer to
  /// "does it fit" is not "yes, exactly", it is "yes, with room to live in".
  ///
  /// The downloader's own number, not a second one: what this draws in red is exactly
  /// what `ModelDownloadFiles.storageShortfall` will refuse to start.
  static var buffer: Int64 { ModelDownloadFiles.storageBuffer }

  /// Whether there is room for the model and the room to spare after it.
  var fits: Bool {
    guard isProposed, let free = free else { return true }
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
    guard let capacity, let free = free else { return 0 }
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
    // What is installed says what it takes and nothing more: the bar already shows the
    // phone's share, and the free figure beside it was a second number to read.
    if !isProposed { return "\(Self.format(needed)) of models" }
    // The one number that matters when it fits: what pressing Download costs. What is left
    // afterwards used to follow it, and read as a second thing to weigh up when the bar
    // and its colour had already said the phone can take it.
    guard let free = free else { return "\(Self.format(needed)) to download" }
    if fits { return "\(Self.format(keeps ?? needed)) to download" }
    // The whole of what it needs beside what there is, so the two numbers can be compared
    // at a glance. "1.65 GB more" next to "9.5 GB free" read as a contradiction; the buffer
    // is part of the need, so it is counted in.
    return "Needs \(Self.format(needed + Self.buffer)) free · \(Self.format(free)) free"
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
