import SwiftUI

/// One thin line over the composer, in the development app only: whether the model is still
/// warming up, and what the phone is spending on the app right now.
///
/// As small as it can be and still be read — a caption in the faintest ink, nothing drawn around
/// it — because it sits on every chat screen the development app shows and must not become part
/// of the design being looked at. While the model loads, the pixels pulse beside "Warming up";
/// once it is ready that side goes quiet and only the readings stay. The readings are the ones
/// `MetricsScreen` explains at length: CPU across every thread, so a figure over 100% is more than
/// one core, and the GPU figure is the Metal memory the app has allocated, since iOS doesn't let
/// an app see how busy the GPU is.
struct DevStatusStrip: View {
  let chat: ChatModel

  @State private var snapshot: DeviceSnapshot?

  private var isWarmingUp: Bool { chat.loadState == .loading }

  var body: some View {
    HStack(spacing: 6) {
      if isWarmingUp {
        PixelThinking(size: 9, color: .secondary)
        Text("Warming up")
          .transition(.opacity)
      }
      Spacer(minLength: 8)
      if let snapshot {
        Text(readings(snapshot))
      }
    }
    .font(.caption2)
    .monospacedDigit()
    .foregroundStyle(.tertiary)
    .padding(.horizontal, 26)
    .padding(.bottom, 6)
    .animation(.easeOut(duration: 0.2), value: isWarmingUp)
    .accessibilityElement(children: .combine)
    .task {
      while !Task.isCancelled {
        // Read off the main thread: counting every thread's time is cheap, but not free.
        snapshot = await Task.detached(priority: .utility) { DeviceMetrics.snapshot() }.value
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func readings(_ snapshot: DeviceSnapshot) -> String {
    "CPU \(MetricFormat.percent(snapshot.cpuPercent))  GPU \(MetricFormat.bytes(snapshot.gpuMemory))"
  }
}
