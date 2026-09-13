import CryptoKit
import Foundation
import Observation
import Security

/// Locks the app behind a passcode of its own.
///
/// The passcode is the app's, not the phone's: four to eight digits, chosen in Settings, kept in
/// the Keychain as a salted hash and nowhere else. The app never learns the phone's passcode and
/// never asks for a face; it compares what was typed against the hash and says yes or no.
///
/// The app locks when it leaves the screen and asks for the passcode as soon as it is back. There
/// is no grace period: a lock that waits a minute is a lock that is off for a minute, and anyone
/// who turns this on has asked for the opposite. There is no recovery either — nothing to send a
/// reset to, on purpose — so Settings says as much: forget it, and it is delete and reinstall.
@MainActor
@Observable
final class AppLock {
  static let minimumLength = 4
  static let maximumLength = 8

  private(set) var isLocked = false
  /// The screen hidden but nothing owed: the app is inactive, not gone. iOS takes the app
  /// switcher's snapshot in that state, and a notification pulled down shouldn't need the passcode
  /// to put back up — so the cover goes on without a prompt and comes off the same way.
  private(set) var isCovered = false
  private(set) var isChecking = false

  /// Whether anything should be on top of the app right now.
  var isShowing: Bool { isLocked || isCovered }

  /// What stood in the way of unlocking, when something did: the wrong passcode, say.
  private(set) var problem: String?

  /// Wrong guesses since the lock came down. Each one makes the next check slower.
  private var failedAttempts = 0

  /// Whether a passcode has been set. Without one there is nothing to lock behind, and `lock()`
  /// does nothing: a lock with no way through is not a lock, it is a locked-out phone.
  static var hasPasscode: Bool { PasscodeStore.load() != nil }

  /// True for the digits a passcode is allowed to be.
  static func isValid(_ code: String) -> Bool {
    (minimumLength...maximumLength).contains(code.count) && code.allSatisfy(\.isNumber)
  }

  static func setPasscode(_ code: String) throws {
    try PasscodeStore.save(PasscodeStore.Record(code))
  }

  static func clearPasscode() {
    PasscodeStore.delete()
  }

  func lock() {
    guard Self.hasPasscode else { return }
    isLocked = true
    isCovered = false
    problem = nil
    failedAttempts = 0
  }

  func cover() {
    if !isLocked { isCovered = true }
  }

  func uncover() {
    isCovered = false
  }

  /// Tries a passcode. True unlocks; false leaves the lock down with `problem` saying so. Wrong
  /// guesses are answered more and more slowly, which is what stands between a lock this simple
  /// and someone with the phone in hand and a minute to spare.
  @discardableResult
  func unlock(with code: String) async -> Bool {
    guard isLocked, !isChecking else { return false }
    isChecking = true
    defer { isChecking = false }
    let matched = await Self.verify(code)
    if matched {
      isLocked = false
      problem = nil
      failedAttempts = 0
      return true
    }
    failedAttempts += 1
    let delay = min(Double(failedAttempts), 10) * 0.5
    try? await Task.sleep(for: .seconds(delay))
    problem = "Wrong passcode"
    return false
  }

  /// Whether a passcode is the one that was set. Off the main thread: the hash is deliberately slow.
  static func verify(_ code: String) async -> Bool {
    guard let record = PasscodeStore.load() else { return false }
    return await Task.detached(priority: .userInitiated) { record.matches(code) }.value
  }
}

/// The passcode's hash, in the Keychain. This device only, and not before the first unlock after
/// a restart — the same protection the chats have. It is not backed up: a restored phone starts
/// with the lock off, which is the right side to fail on.
enum PasscodeStore {
  struct Record: Codable {
    let salt: Data
    let hash: Data
    /// How many times the hash is folded over itself. Enough to make guessing offline slow,
    /// not enough to notice at the lock screen.
    static let rounds = 50_000

    init(_ code: String) {
      var bytes = [UInt8](repeating: 0, count: 16)
      _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      salt = Data(bytes)
      hash = Self.digest(code, salt: salt)
    }

    func matches(_ code: String) -> Bool {
      let candidate = Self.digest(code, salt: salt)
      // Compared in full whatever the first differing byte, so timing says nothing.
      return candidate.count == hash.count && zip(candidate, hash).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func digest(_ code: String, salt: Data) -> Data {
      var digest = Data(SHA256.hash(data: salt + Data(code.utf8)))
      for _ in 1..<rounds {
        digest = Data(SHA256.hash(data: digest + salt))
      }
      return digest
    }
  }

  private static let service = (Bundle.main.bundleIdentifier ?? "com.anvilbase.anvil") + ".applock"
  private static let account = "passcode"

  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  static func load() -> Record? {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return try? JSONDecoder().decode(Record.self, from: data)
  }

  static func save(_ record: Record) throws {
    let data = try JSONEncoder().encode(record)
    delete()
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(
        domain: NSOSStatusErrorDomain, code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "The passcode couldn't be saved."])
    }
  }

  static func delete() {
    SecItemDelete(query as CFDictionary)
  }
}
