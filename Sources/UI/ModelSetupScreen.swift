import SwiftUI

/// The first screen, shown until a model has been imported. It explains how to copy one onto the
/// phone and watches for the file arriving.
struct ModelSetupScreen: View {
  let library: ModelLibrary

  private var appName: String { AppFlavor.appName }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          status
          instructions
          Button {
            Task { await library.refresh() }
          } label: {
            Label("Check again", systemImage: "arrow.clockwise")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(isBusy)
        }
        .padding()
      }
      .navigationTitle("Add a model")
    }
    .task {
      // Notice a file that arrives while this screen is open.
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        await library.refresh()
      }
    }
  }

  private var isBusy: Bool {
    switch library.state {
    case .checking, .waitingForCopy: true
    default: false
    }
  }

  @ViewBuilder
  private var status: some View {
    switch library.state {
    case .checking, .ready:
      HStack(spacing: 12) {
        ProgressView()
        Text("Looking for a model…")
      }

    case .missing:
      Label("No model found", systemImage: "tray")
        .font(.headline)

    case .waitingForCopy(let fileName):
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          ProgressView()
          Text("Waiting for \(fileName) to finish copying…")
            .font(.headline)
        }
        Text(
          "A 3–4 GB file takes several minutes. Keep \(appName) open; it imports the model as soon "
            + "as the copy is complete."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }

    case .failed(let message):
      VStack(alignment: .leading, spacing: 8) {
        Label("Couldn't import the model", systemImage: "exclamationmark.triangle")
          .font(.headline)
          .foregroundStyle(.orange)
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var instructions: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        "\(appName) runs a model entirely on this iPhone. The model file (about 3–4 GB) is copied "
          + "on separately, so it isn't part of the app.")

      VStack(alignment: .leading, spacing: 8) {
        Text("From a Mac (fastest)")
          .font(.headline)
        Text("1. Download a **.litertlm** model file on your Mac.")
        Text("2. Connect this iPhone with a cable and open **Finder**.")
        Text("3. Select the iPhone in the sidebar and open the **Files** tab.")
        Text("4. Drag the .litertlm file onto **\(appName)**.")
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("From the Files app")
          .font(.headline)
        Text("Move the .litertlm file into **On My iPhone › \(appName)**.")
      }

      Text(
        "After the copy finishes, the model moves into the app's private storage and is excluded "
          + "from iCloud backups."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }
}
