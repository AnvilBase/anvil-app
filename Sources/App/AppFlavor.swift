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

  /// Whether this build is showing what only the development app has: the hammer in the top bar,
  /// the timings under a reply, the metrics in Settings.
  ///
  /// The development app can be asked to present itself as the public one, so a change can be
  /// looked at the way it will ship without swapping apps. The switch only ever takes things away:
  /// it is `&&`, not `||`, so the public app cannot be handed development features by editing a
  /// settings file — `isDevelopment` is compiled in and false there whatever this says.
  static func showsDevelopmentFeatures(_ settings: AppSettings) -> Bool {
    isDevelopment && !settings.previewAsPublic
  }

  /// The app's name as it appears on the Home Screen, read from the bundle so the name lives in one
  /// place (Config/Public.xcconfig and Config/Dev.xcconfig).
  static let appName: String = {
    let info = Bundle.main.infoDictionary
    let name =
      info?["CFBundleDisplayName"] as? String ?? info?[kCFBundleNameKey as String] as? String
    return name?.isEmpty == false ? name! : "Anvil"
  }()

  /// What the product is called, whichever build this is.
  ///
  /// The development app is a build of Anvil, not a different product, so where the app introduces
  /// itself — the welcome screen — it says Anvil in both. `appName` is for where the build genuinely
  /// matters: the Home Screen, and anything telling you which of the two you are looking at.
  static let productName = "Anvil"

  /// Marks stored items that must not be shared between the two apps.
  static let storageNamespace: String = Bundle.main.bundleIdentifier ?? "com.anvilbase.AnvilAI"
}
