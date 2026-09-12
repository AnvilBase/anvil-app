import Foundation

/// Which build this is: the public app or the development app.
///
/// Both apps are built from the same code in `Sources/`. The development target defines `ANVIL_DEV`,
/// which is the only switch that separates them — today it adds the developer screen, and later it
/// gates tools that aren't ready to ship (see `ToolRegistry`).
enum AppFlavor: String, Sendable {
  case release
  case development

  #if ANVIL_DEV
    static let current = AppFlavor.development
  #else
    static let current = AppFlavor.release
  #endif

  static var isDevelopment: Bool { current == .development }

  /// The app's name as it appears on the Home Screen, read from the bundle so the name lives in one
  /// place (Config/Public.xcconfig and Config/Dev.xcconfig).
  static let appName: String = {
    let info = Bundle.main.infoDictionary
    let name =
      info?["CFBundleDisplayName"] as? String ?? info?[kCFBundleNameKey as String] as? String
    return name?.isEmpty == false ? name! : "Anvil AI"
  }()

  /// Marks stored items that must not be shared between the two apps.
  static let storageNamespace: String = Bundle.main.bundleIdentifier ?? "com.anvilbase.AnvilAI"
}
