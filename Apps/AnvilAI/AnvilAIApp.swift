import SwiftUI

/// Entry point for the public app.
///
/// Everything it shows comes from `AnvilRootScene` in `Sources/`, which the development app uses
/// too. The two apps differ only in the flavor their build declares (`AppFlavor`), so a feature can
/// ship in the development app first and move to this one by deleting one `#if ANVIL_DEV`.
@main
struct AnvilAIApp: App {
  var body: some Scene {
    AnvilRootScene()
  }
}
