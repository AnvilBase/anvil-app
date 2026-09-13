import SwiftUI

/// The first screen, shown until a model has been installed. It offers the models Anvil publishes
/// and downloads the chosen one.
struct ModelSetupScreen: View {
  @Environment(\.theme) private var theme
  let library: ModelLibrary

  @State private var catalog: [CatalogModel] = []
  @State private var catalogError: String?
  @State private var isLoadingCatalog = true

  /// The mark beside a model's name, tied to the name's own text style so the two are the same
  /// height whatever size the type is set to — rather than a fixed number that only looks right at
  /// one of them.
  @ScaledMetric(relativeTo: .headline) private var markSize: CGFloat = 16

  private var downloader: ModelDownloader { library.downloader }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          switch library.state {
          case .failed(let message):
            installFailure(message)
          default:
            installing
          }
        }
        .padding()
      }
      .navigationTitle("Select a model")
    }
    .task { await loadCatalog() }
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
    if isLoadingCatalog {
      ProgressView()
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
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
      Text("No models published yet.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else {
      ForEach(catalog) { model in
        modelCard(model)
      }
      Toggle("Download over cellular", isOn: cellularBinding)
        .font(.subheadline)
    }
  }

  private var cellularBinding: Binding<Bool> {
    Binding(get: { downloader.allowsCellular }, set: { downloader.allowsCellular = $0 })
  }

  private func modelCard(_ model: CatalogModel) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      // The name gets the whole row: nothing here is ever cut short with an ellipsis, so the badge
      // sits on its own line underneath rather than competing for the width.
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        PixelAnvil(size: markSize, color: tint(of: model))
          // Sat on the text's baseline rather than hung off the top of the row, so the mark and the
          // name read as one line however large the type is.
          .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        Text(model.name)
          .font(.headline)
        Spacer(minLength: 8)
        Text(model.formattedSize)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize()
      }

      if model.isRecommended {
        // An outline rather than a filled chip: it is a note about the model, not a second thing
        // to press.
        Text("Recommended")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.primary)
          .fixedSize()
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .overlay(Capsule().strokeBorder(.primary.opacity(0.55), lineWidth: 1))
      }

      Text(model.parameters.map { "\(model.summary) (\($0))" } ?? model.summary)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if let basedOn = model.basedOn {
        Text("Based on \(basedOn)")
          .font(.footnote)
          .foregroundStyle(.tertiary)
      }

      // The same pill the welcome screen's Continue is: on this screen there is one thing to do,
      // and it should look like the one thing to do everywhere else in the app.
      Button {
        library.install(model)
      } label: {
        Label("Download", systemImage: "arrow.down.circle")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .frame(height: ChatStyle.inlineControl)
          .background(theme.sendFill, in: Capsule())
          .foregroundStyle(theme.sendGlyph)
      }
      .buttonStyle(.plain)
    }
    .padding()
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
  }

  /// The mark beside a model's name, tinted so the two are told apart before you have read either:
  /// Spark warm, Forge hotter. Anvil publishes two today and the catalog says nothing about colour,
  /// so this is the one thing about a model the app knows by name — anything else gets the plain
  /// mark rather than a colour picked for it.
  private func tint(of model: CatalogModel) -> Color {
    switch model.id {
    case "anvil-spark": .orange
    case "anvil-forge": .red
    default: .primary
    }
  }

  private func resumeCard(_ model: CatalogModel) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(model.name) is part-downloaded")
        .font(.headline)
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
          // The same ink Download is filled with, rather than the accent: on this screen the one
          // thing you started is the one thing that should be showing its progress in it.
          .tint(theme.sendFill)
        HStack {
          Text(transferred)
          Spacer()
          Text("\(Int(downloader.fraction * 100))%")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()

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

  // MARK: - When installing fails

  private func installFailure(_ message: String) -> some View {
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
