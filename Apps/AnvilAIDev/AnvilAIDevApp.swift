import SwiftUI

/// Entry point for the development app.
///
/// It installs alongside the public app with its own bundle identifier, so both can run on one
/// iPhone with separate chats, settings, and imported model. The shared code in `Sources/` is
/// identical; this target additionally defines `ANVIL_DEV`, which turns on the developer screen and
/// any tools registered for development builds only (see `ToolRegistry`).
@main
struct AnvilAIDevApp: App {
  var body: some Scene {
    AnvilRootScene()
  }
}
