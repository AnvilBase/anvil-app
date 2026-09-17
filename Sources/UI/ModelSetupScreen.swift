import SwiftUI

/// The first screen, shown until a chat model has been installed. What Anvil offers, one card
/// each — Anvil Core, free and the way in, and Anvil Pro, which is the unrestricted model and the
/// one that makes pictures, as one thing — with the files, their sizes and their checksums all
/// coming from anvilai.com. Anvil Core's card says Recommended: press Download and leave it
/// running. Anvil Pro's card leads to the paywall until Pro is active, and a plan the catalog has
/// announced but not published yet says so.
struct ModelSetupScreen: View {
  @Environment(\.theme) private var theme
  @Environment(ProAccess.self) private var pro
  let library: ModelLibrary
  /// Straight into the chat without a model. Passed only by the development app, for looking at
  /// the screens without waiting on gigabytes; the public app never offers it.
  var onSkip: (() -> Void)? = nil

  @State private var plans: [ModelPlan] = []
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
  /// card of the plan it belongs to, so each says how far its own is.
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
    } else if !plans.isEmpty {
      ForEach(plans) { plan in
        card(for: plan)
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

  private func card(for plan: ModelPlan) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        // The mark says which of the two this is before the name does: the plain mark for Core,
        // the gold one Pro wears everywhere else in the app.
        Group {
          if plan.isPro {
            GoldAnvil(size: markSize)
          } else {
            PixelAnvil(size: markSize)
          }
        }
        // Sat on the text's baseline rather than hung off the top of the row, so the mark and the
        // name read as one line however large the type is.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        Text(plan.name)
          .font(.title2.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
        if plan.isRecommended {
          Spacer()
          badge("Recommended")
        } else if plan.isPro {
          Spacer()
          badge("Pro")
        }
      }

      Text(plan.summary)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      // The two numbers worth knowing before pressing Download: what it costs in space — the
      // whole plan, both files of it — and how big a model it is. An announced plan has no file
      // yet, so no size.
      HStack(spacing: 0) {
        if !plan.isComingSoon {
          stat("Size", plan.formattedSize)
        }
        if let parameters = plan.parameters {
          if !plan.isComingSoon { Divider().frame(height: 32) }
          stat("Parameters", parameters)
        }
      }

      action(for: plan)
    }
    .padding(18)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    // Anvil Pro, without it, stands back from the plan that can be downloaded now. Faded, not
    // disabled: the lock on it still leads to the Pro page.
    .opacity(plan.isPro && !pro.isUnlocked ? 0.55 : 1)
    .animation(.easeInOut(duration: 0.2), value: pro.isUnlocked)
  }

  /// What a card lets you do: download the plan — or watch it come, stop it, carry it on after
  /// the app was closed, or try again after it stopped — go to the paywall for Anvil Pro, or, for
  /// one that isn't published yet or is already here, see that.
  @ViewBuilder
  private func action(for plan: ModelPlan) -> some View {
    let downloader = library.downloader(for: plan)
    if let downloader, downloader.isActive {
      VStack(alignment: .leading, spacing: 10) {
        // One bar for the plan, not one per file: Anvil Pro is two downloads and one thing being
        // downloaded, so the bar counts what is already here as ground covered.
        let progress = library.progress(of: plan)
        ProgressView(value: progress?.fraction ?? downloader.fraction)
          // The same ink Download is filled with, rather than the accent: on this screen the one
          // thing you started is the one thing that should be showing its progress in it.
          .tint(theme.sendFill)
        HStack {
          Text(transferred(progress) ?? transferred(downloader))
          Spacer()
          Text("\(Int((progress?.fraction ?? downloader.fraction) * 100))%")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        Button("Cancel", role: .destructive) { Task { await library.cancelInstall(plan) } }
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
          // Try again picks the plan up where it stopped: what has already landed is not fetched
          // twice.
          Button("Try again") { library.install(plan) }
            .buttonStyle(.borderedProminent)
          Button("Start over", role: .destructive) { Task { await library.cancelInstall(plan) } }
            .buttonStyle(.bordered)
        }
      }
    } else if library.isInterrupted(plan) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Part-downloaded")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        HStack {
          Button("Resume") { library.install(plan) }
            .buttonStyle(.borderedProminent)
          Button("Start over", role: .destructive) { Task { await library.cancelInstall(plan) } }
            .buttonStyle(.bordered)
        }
      }
    } else if library.isInstalled(plan) {
      Label("Installed", systemImage: "checkmark.circle")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else if plan.isComingSoon {
      Label("Coming soon", systemImage: "clock")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else if plan.isPro, !pro.isUnlocked {
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
      // A plan with nothing to chat with in it — its chat model announced but not published yet,
      // leaving only the one that makes pictures — waits for a model to chat with: a picture is
      // made for a reply, so there has to be a reply.
      let waitsForChatModel = plan.textModel == nil && !library.hasTextModel
      VStack(spacing: 8) {
        // The same ink the welcome screen's Continue is: the one thing to press on this screen.
        Button {
          library.install(plan)
        } label: {
          Label("Download", systemImage: "arrow.down.circle")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: ChatStyle.inlineControl)
            .background(theme.sendFill, in: Capsule())
            .foregroundStyle(theme.sendGlyph)
            .opacity(waitsForChatModel ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(waitsForChatModel)
        if waitsForChatModel {
          Text("Download Anvil Core first")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// The small outline that marks a card — Recommended on Anvil Core, Pro on Anvil Pro — as it
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

  private func transferred(_ progress: (received: Int64, total: Int64, fraction: Double)?) -> String? {
    guard let progress else { return nil }
    return "\(Self.format(progress.received)) of \(Self.format(progress.total))"
  }

  private func transferred(_ downloader: ModelDownloader) -> String {
    "\(Self.format(downloader.receivedBytes)) of \(Self.format(downloader.totalBytes))"
  }

  private static func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
      // As the catalog lists them, read as plans: the order is decided there, once, for every
      // screen.
      let catalog = try await ModelCatalog.load()
      plans = ModelPlan.plans(from: catalog)
    } catch {
      catalogError = error.localizedDescription
    }
    isLoadingCatalog = false
  }
}
