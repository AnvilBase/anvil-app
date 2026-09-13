import Darwin
import Foundation

/// What phone this is and what it runs, for a bug report. Read once; neither changes while the
/// app is open.
enum DeviceInfo {
  /// Apple's identifier for the hardware, "iPhone17,1" — what a crash log says, and what tells a
  /// model's behaviour apart between phones more exactly than a marketing name would.
  static let model: String = {
    var system = utsname()
    uname(&system)
    return withUnsafeBytes(of: &system.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
  }()

  /// "26.0 (23A340)", as iOS reports it.
  static let systemVersion: String = {
    let version = ProcessInfo.processInfo.operatingSystemVersionString
    // ProcessInfo says "Version 26.0 (Build 23A340)"; the words are noise beside a version.
    return
      version
      .replacingOccurrences(of: "Version ", with: "")
      .replacingOccurrences(of: "Build ", with: "")
  }()
}
