import Foundation

/// Files under Application Support that hold personal data: chats, photos, memories, settings, usage
/// numbers. They are written with complete file protection (unreadable while the phone is locked) and
/// excluded from backups, so nothing personal leaves the device through iCloud.
enum PrivateFiles {
  static func directory(_ name: String) throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var directory = support.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    return directory
  }

  static func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic, .completeFileProtection])
  }

  static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try write(JSONEncoder().encode(value), to: url)
  }

  static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }
}
