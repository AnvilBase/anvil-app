import SwiftUI

/// The first screen, shown until a model has been installed. It offers the models Anvil publishes
/// and downloads the chosen one, and explains how to copy a file across by hand for anyone who would
/// rather do that.
struct ModelSetupScreen: View {
  let library: ModelLibrary

  @State private var catalog: [CatalogModel] = []
  @State private var catalogError: String?
  @State private var isLoadingCatalog = true
  @State private var showsManualImport = false

  private var appName: String { AppFlavor.appName }
  private var downloader: ModelDownloader { library.downloader }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          switch library.state {
          case .waitingForCopy(let fileName):
            copying(fileName)
          case .failed(let message):
            importFailure(message)
          default:
            installing
          }
          manualImport
        }
        .padding()
      }
      .navigationTitle("Add a model")
    }
    .task { await loadCatalog() }
    .task {
      // Notice a file that arrives while this screen is open. A download owns the models folder
      // while it runs, so this does nothing in the meantime.
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        await library.refresh()
      }
    }
  }

  // MARK: - Installing from anvilai.com

  @ViewBuilder
  private var installing: some View {
    if downloader.isActive || hasFailedDownload {
      downloadCard
    } else if let interrupted = library.interruptedDownload {
      resumeCard(interrupted)
    } else {
      catalogList
    }
  }

  private var hasFailedDownload: Bool {
    if case .failed = downloader.phase { return true }
    return false
  }

  @ViewBuilder
  private var catalogList: some View {
    Text("\(appName) runs a model entirely on this iPhone. Nothing you type ever leaves it.")
      .font(.subheadline)
      .foregroundStyle(.secondary)

    if isLoadingCatalog {
      HStack(spacing: 12) {
        ProgressView()
        Text("Looking for models…")
      }
    } else if let catalogError {
      VStack(alignment: .leading, spacing: 12) {
        Label("Couldn't reach anvilai.com", systemImage: "wifi.exclamationmark")
          .font(.headline)
        Text(catalogError)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Button("Try again") { Task { await loadCatalog() } }
          .buttonStyle(.bordered)
      }
    } else if catalog.isEmpty {
      Text("No models are published yet. You can still copy one across from a Mac.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else {
      ForEach(catalog) { model in
        modelCard(model)
      }
      Toggle("Download over cellular", isOn: cellularBinding)
        .font(.subheadline)
      Text("A model is a few gigabytes. Wi‑Fi is usually the better idea.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var cellularBinding: Binding<Bool> {
    Binding(get: { downloader.allowsCellular }, set: { downloader.allowsCellular = $0 })
  }

  private func modelCard(_ model: CatalogModel) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(model.name)
          .font(.headline)
        if model.isRecommended {
          Text("Recommended")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
        }
        Spacer()
        Text(model.formattedSize)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Text(model.summary)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if let provenance = provenance(of: model) {
        Text(provenance)
          .font(.footnote)
          .foregroundStyle(.tertiary)
      }

      Button {
        library.install(model)
      } label: {
        Label("Download", systemImage: "arrow.down.circle")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
    .padding()
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
  }

  /// What the model is and what it's licensed under. A model that records only its licence still
  /// shows it: the licence has to reach whoever downloads the file, not just the person who
  /// published it.
  private func provenance(of model: CatalogModel) -> String? {
    switch (model.basedOn, model.license) {
    case let (basedOn?, license?): "Based on \(basedOn) · \(license)"
    case let (basedOn?, nil): "Based on \(basedOn)"
    case let (nil, license?): license
    case (nil, nil): nil
    }
  }

  private func resumeCard(_ model: CatalogModel) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(model.name) is part-downloaded")
        .font(.headline)
      Text("Carrying on picks up where it stopped. Nothing already downloaded is fetched again.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      HStack {
        Button("Resume") { library.install(model) }
          .buttonStyle(.borderedProminent)
        Button("Start over", role: .destructive) { Task { await library.cancelInstall() } }
          .buttonStyle(.bordered)
      }
    }
    .padding()
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
  }

  private var downloadCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(downloader.model?.name ?? "Downloading")
        .font(.headline)

      if case .failed(let message) = downloader.phase {
        Label("Download stopped", systemImage: "exclamationmark.triangle")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.orange)
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        HStack {
          if let model = downloader.model {
            Button("Try again") { library.install(model) }
              .buttonStyle(.borderedProminent)
          }
          Button("Start over", role: .destructive) { Task { await library.cancelInstall() } }
            .buttonStyle(.bordered)
        }
      } else {
        ProgressView(value: downloader.fraction)
        HStack {
          Text(transferred)
          Spacer()
          Text("\(Int(downloader.fraction * 100))%")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()

        Text(phaseDescription)
          .font(.footnote)
          .foregroundStyle(.secondary)

        Button("Cancel", role: .destructive) { Task { await library.cancelInstall() } }
          .buttonStyle(.bordered)
      }
    }
    .padding()
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
  }

  private var transferred: String {
    let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    return "\(format(downloader.receivedBytes)) of \(format(downloader.totalBytes))"
  }

  private var phaseDescription: String {
    switch downloader.phase {
    case .downloading:
      "Part \(downloader.partNumber) of \(downloader.partCount). You can leave \(appName); the "
        + "download carries on."
    case .checking:
      "Checking part \(downloader.partNumber) of \(downloader.partCount)…"
    case .installing:
      "Finishing up…"
    default:
      ""
    }
  }

  // MARK: - Copying a file across by hand

  private func copying(_ fileName: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        ProgressView()
        Text("Waiting for \(fileName) to finish copying…")
          .font(.headline)
      }
      Text(
        "A file this size takes several minutes. Keep \(appName) open; it imports the model as soon "
          + "as the copy is complete."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
  }

  private func importFailure(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Couldn't install the model", systemImage: "exclamationmark.triangle")
        .font(.headline)
        .foregroundStyle(.orange)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Button("Check again") { Task { await library.refresh() } }
        .buttonStyle(.bordered)
    }
  }

  private var manualImport: some View {
    DisclosureGroup("Copy a file across instead", isExpanded: $showsManualImport) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Any LiteRT-LM **.litertlm** file works, including the ones Anvil publishes.")
          .font(.subheadline)

        VStack(alignment: .leading, spacing: 8) {
          Text("From a Mac (fastest)")
            .font(.headline)
          Text("1. Download a **.litertlm** model file on your Mac.")
          Text("2. Connect this iPhone with a cable and open **Finder**.")
          Text("3. Select the iPhone in the sidebar and open the **Files** tab.")
          Text("4. Drag the .litertlm file onto **\(appName)**.")
        }
        .font(.subheadline)

        VStack(alignment: .leading, spacing: 8) {
          Text("From the Files app")
            .font(.headline)
          Text("Move the .litertlm file into **On My iPhone › \(appName)**.")
            .font(.subheadline)
        }

        Text(
          "After the copy finishes, the model moves into the app's private storage and is excluded "
            + "from iCloud backups."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)

        Button("Check again") { Task { await library.refresh() } }
          .buttonStyle(.bordered)
      }
      .padding(.top, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.headline)
  }

  private func loadCatalog() async {
    isLoadingCatalog = true
    catalogError = nil
    do {
      catalog = try await ModelCatalog.load()
    } catch {
      catalogError = error.localizedDescription
    }
    isLoadingCatalog = false
  }
}
