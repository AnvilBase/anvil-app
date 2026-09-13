import SwiftUI

/// The first screen, shown until a chat model has been installed. The models the catalog
/// publishes, one card each, in the catalog's order — Anvil Core, Anvil Raw, Anvil Dream — with the
/// file, its size and its checksums all coming from anvilai.com. Anvil Core, the free one, is the
/// way in and the default, and its card says Recommended: press Download and leave it running. A
/// Pro model's card leads to the paywall until Pro is active, and one the catalog has announced but
/// not published yet says so.
struct ModelSetupScreen: View {
  @Environment(\.theme) private var theme
  @Environment(ProAccess.self) private var pro
  let library: ModelLibrary
  /// Straight into the chat without a model. Passed only by the development app, for looking at
  /// the screens without waiting on gigabytes; the public app never offers it.
  var onSkip: (() -> Void)? = nil

  @State private var models: [CatalogModel] = []
  @State private var catalogError: String?
  @State private var isLoadingCatalog = true

  /// The mark beside the model's name, tied to the name's own text style so the two are the same
  /// height whatever size the type is set to — rather than a fixed number that only looks right at
  /// one of them.
  @ScaledMetric(relativeTo: .title2) private var markSize: CGFloat = 22

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
      .navigationTitle("Choose a model")
      .toolbar {
        if let onSkip {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Skip", action: onSkip)
          }
        }
      }
    }
    .task { await loadCatalog() }
    .alert("Not enough storage on your phone", isPresented: storageAlertShowing) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(library.storageWarning ?? "")
    }
  }

  private var storageAlertShowing: Binding<Bool> {
    Binding(
      get: { library.storageWarning != nil },
      set: { if !$0 { library.storageWarning = nil } })
  }

  // MARK: - Installing from anvilai.com

  /// The cards, always: a download under way, stopped, or waiting to be carried on shows on the
  /// card of the model it belongs to, so two can be on their way at once and each says how far.
  @ViewBuilder
  private var installing: some View {
    modelCards
  }

  @ViewBuilder
  private var modelCards: some View {
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
    } else if !models.isEmpty {
      ForEach(models) { model in
        card(for: model)
      }
      Toggle("Download over cellular", isOn: cellularBinding)
        .font(.subheadline)
    } else {
      Text("No model is published yet.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var cellularBinding: Binding<Bool> {
    Binding(get: { library.allowsCellular }, set: { library.allowsCellular = $0 })
  }

  /// Whether this catalog model is already on the phone. Anvil Dream can be, while this screen is
  /// still up waiting for a chat model.
  private func isInstalled(_ model: CatalogModel) -> Bool {
    library.installed.contains { $0.catalogID == model.id || $0.fileName == model.fileName }
  }

  private func card(for model: CatalogModel) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        PixelAnvil(size: markSize)
          // Sat on the text's baseline rather than hung off the top of the row, so the mark and the
          // name read as one line however large the type is.
          .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        Text(model.name)
          .font(.title2.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
        if model.isRecommended {
          Spacer()
          badge("Recommended")
        } else if model.isPro {
          Spacer()
          badge("Pro")
        }
      }

      Text(model.summary)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      // The two numbers worth knowing before pressing Download: what it costs in space, and how
      // big a model it is. An announced model has no file yet, so no size.
      HStack(spacing: 0) {
        if !model.isComingSoon {
          stat("Size", model.formattedSize)
        }
        if let parameters = model.parameters {
          if !model.isComingSoon { Divider().frame(height: 32) }
          stat("Parameters", parameters)
        }
      }

      if let basedOn = model.basedOn {
        Text("Based on \(basedOn)")
          .font(.footnote)
          .foregroundStyle(.tertiary)
      }

      action(for: model)
    }
    .padding(18)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
  }

  /// What a card lets you do: download the model — or watch it come, stop it, carry it on after
  /// the app was closed, or try again after it stopped — go to the paywall for a Pro one, or, for
  /// one that isn't published yet or is already here, see that.
  @ViewBuilder
  private func action(for model: CatalogModel) -> some View {
    let downloader = library.downloader(for: model)
    if let downloader, downloader.isActive {
      VStack(alignment: .leading, spacing: 10) {
        ProgressView(value: downloader.fraction)
          // The same ink Download is filled with, rather than the accent: on this screen the one
          // thing you started is the one thing that should be showing its progress in it.
          .tint(theme.sendFill)
        HStack {
          Text(transferred(downloader))
          Spacer()
          Text("\(Int(downloader.fraction * 100))%")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        Button("Cancel", role: .destructive) { Task { await library.cancelInstall(model) } }
          .buttonStyle(.bordered)
      }
    } else if let downloader, case .failed(let message) = downloader.phase {
      VStack(alignment: .leading, spacing: 10) {
        Label("Download stopped", systemImage: "exclamationmark.triangle")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.orange)
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        HStack {
          Button("Try again") { library.install(model) }
            .buttonStyle(.borderedProminent)
          Button("Start over", role: .destructive) { Task { await library.cancelInstall(model) } }
            .buttonStyle(.bordered)
        }
      }
    } else if library.interruptedDownloads.contains(where: { $0.id == model.id }) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Part-downloaded")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        HStack {
          Button("Resume") { library.install(model) }
            .buttonStyle(.borderedProminent)
          Button("Start over", role: .destructive) { Task { await library.cancelInstall(model) } }
            .buttonStyle(.bordered)
        }
      }
    } else if isInstalled(model) {
      Label("Installed", systemImage: "checkmark.circle")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else if model.isComingSoon {
      Label("Coming soon", systemImage: "clock")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else if model.isPro, !pro.isUnlocked {
      NavigationLink {
        ProScreen()
      } label: {
        Label("Anvil Pro", systemImage: "lock")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .frame(height: ChatStyle.inlineControl)
          .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
      }
      .buttonStyle(.plain)
    } else {
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
  }

  /// The small outline that marks a card — Recommended on Anvil Core, Pro on the others — as it
  /// marks a Pro row in Settings.
  private func badge(_ text: String) -> some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
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

  private func transferred(_ downloader: ModelDownloader) -> String {
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
      // As the catalog lists them: the order is decided there, once, for every screen.
      models = try await ModelCatalog.load()
    } catch {
      catalogError = error.localizedDescription
    }
    isLoadingCatalog = false
  }
}
