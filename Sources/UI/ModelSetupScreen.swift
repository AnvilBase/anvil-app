import SwiftUI

/// The first screen, shown until the model has been installed. There is one model to install — the
/// app calls it the Anvil Model — and one thing to do here: press Download and leave it running.
///
/// Underneath it is whichever entry the catalog publishes as `anvil-forge`, so the file, its size
/// and its checksums all still come from anvilai.com; only the name is decided here. If the catalog
/// stops publishing that entry, the recommended free one stands in, then the first free one. Pro
/// models and image models are never offered here: this screen is the way in, and both of those
/// are found in Settings.
struct ModelSetupScreen: View {
  @Environment(\.theme) private var theme
  let library: ModelLibrary
  /// Straight into the chat without a model. Passed only by the development app, for looking at
  /// the screens without waiting on gigabytes; the public app never offers it.
  var onSkip: (() -> Void)? = nil

  @State private var model: CatalogModel?
  @State private var catalogError: String?
  @State private var isLoadingCatalog = true

  /// What the model is called on this screen, whatever the catalog calls it.
  static let displayName = "Anvil Model"
  /// The catalog entry that is the model. Forge, the everyday one.
  private static let catalogID = "anvil-forge"

  /// The mark beside the model's name, tied to the name's own text style so the two are the same
  /// height whatever size the type is set to — rather than a fixed number that only looks right at
  /// one of them.
  @ScaledMetric(relativeTo: .title2) private var markSize: CGFloat = 22

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
      .navigationTitle("Install the AI model")
      .toolbar {
        if let onSkip {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Skip", action: onSkip)
          }
        }
      }
    }
    .task { await loadCatalog() }
  }

  // MARK: - Installing from anvilai.com

  @ViewBuilder
  private var installing: some View {
    if downloader.isActive || hasFailedDownload {
      downloadCard
    } else if library.interruptedDownload != nil {
      resumeCard
    } else {
      modelCard
    }
  }

  private var hasFailedDownload: Bool {
    if case .failed = downloader.phase { return true }
    return false
  }

  @ViewBuilder
  private var modelCard: some View {
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
    } else if let model {
      card(for: model)
      Toggle("Download over cellular", isOn: cellularBinding)
        .font(.subheadline)
    } else {
      Text("The model isn't published yet.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var cellularBinding: Binding<Bool> {
    Binding(get: { downloader.allowsCellular }, set: { downloader.allowsCellular = $0 })
  }

  private func card(for model: CatalogModel) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        PixelAnvil(size: markSize)
          // Sat on the text's baseline rather than hung off the top of the row, so the mark and the
          // name read as one line however large the type is.
          .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        Text(Self.displayName)
          .font(.title2.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }

      Text("Runs entirely on this iPhone. Nothing you type leaves it.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      // The two numbers worth knowing before pressing Download: what it costs in space, and how
      // big a model it is.
      HStack(spacing: 0) {
        stat("Size", model.formattedSize)
        if let parameters = model.parameters {
          Divider().frame(height: 32)
          stat("Parameters", parameters)
        }
      }

      if let basedOn = model.basedOn {
        Text("Based on \(basedOn)")
          .font(.footnote)
          .foregroundStyle(.tertiary)
      }

      // The same ink the welcome screen's Continue is: the one thing to press on this screen.
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
    .padding(18)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
  }

  private func stat(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline)
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var resumeCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(Self.displayName) is part-downloaded")
        .font(.headline)
      HStack {
        if let interrupted = library.interruptedDownload {
          Button("Resume") { library.install(interrupted) }
            .buttonStyle(.borderedProminent)
        }
        Button("Start over", role: .destructive) { Task { await library.cancelInstall() } }
          .buttonStyle(.bordered)
      }
    }
    .padding()
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
  }

  private var downloadCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(Self.displayName)
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
      let catalog = try await ModelCatalog.load()
      let free = catalog.filter { !$0.isPro && !$0.isImage }
      model =
        free.first { $0.id == Self.catalogID }
        ?? free.first { $0.isRecommended }
        ?? free.first
    } catch {
      catalogError = error.localizedDescription
    }
    isLoadingCatalog = false
  }
}
