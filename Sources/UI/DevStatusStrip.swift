import SwiftUI

/// One thin line over the composer, in the development app only: whether the model is still
/// warming up, and what the phone is spending on the app right now.
///
/// As small as it can be and still be read — a caption in the faintest ink, nothing drawn around
/// it — because it sits on every chat screen the development app shows and must not become part
/// of the design being looked at. While the model loads, a small flame flickers beside "Warming up";
/// once it is ready that side goes quiet and only the readings stay. Warming up is a flame,
/// because that is what warming up is; it flickers rather than spins. The readings are the ones
/// `MetricsScreen` explains at length: CPU across every thread, so a figure over 100% is more than
/// one core, the GPU figure is the Metal memory the app has allocated, since iOS doesn't let
/// an app see how busy the GPU is, and Heat is the thermal band iOS reports, since it gives no
/// temperature in degrees.
struct DevStatusStrip: View {
  let chat: ChatModel

  @State private var snapshot: DeviceSnapshot?
  /// The phone's temperature in Fahrenheit, read with the snapshot — see `DeviceTemperature`.
  @State private var fahrenheit: Double?

  private var isWarmingUp: Bool { chat.loadState == .loading }

  var body: some View {
    HStack(spacing: 6) {
      if isWarmingUp {
        WarmingFlame()
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
        let sample = await Task.detached(priority: .utility) { () -> (DeviceSnapshot, Double?) in
          var degrees: Double?
          #if ANVIL_DEV
            degrees = DeviceTemperature.fahrenheit()
          #endif
          return (DeviceMetrics.snapshot(), degrees)
        }.value
        snapshot = sample.0
        fahrenheit = sample.1
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func readings(_ snapshot: DeviceSnapshot) -> String {
    "CPU \(MetricFormat.percent(snapshot.cpuPercent))  GPU \(MetricFormat.bytes(snapshot.gpuMemory))"
      + "  \(heat(snapshot.thermalState))"
  }

  /// Degrees Fahrenheit when the phone's sensors can be read — see `DeviceTemperature` — and
  /// otherwise the band iOS reports, which is the only public word on the matter.
  private func heat(_ state: ProcessInfo.ThermalState) -> String {
    if let fahrenheit { return String(format: "%.0f°F", fahrenheit) }
    return "Heat \(Self.band(state))"
  }

  /// The thermal band, in one word, the way the rest of the line reads.
  private static func band(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "Normal"
    case .fair: "Fair"
    case .serious: "Serious"
    case .critical: "Critical"
    @unknown default: "Unknown"
    }
  }
}

/// A small flame, flickering: it leans and licks a little taller on one beat and settles on the
/// next, and its layers run through the symbol's own variable colour so the tip burns brighter
/// than the base. Orange, the one bit of colour on the line, and small enough to stay a caption.
private struct WarmingFlame: View {
  @State private var licking = false

  var body: some View {
    Image(systemName: "flame.fill")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.orange)
      .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: true)
      .scaleEffect(x: licking ? 0.94 : 1.04, y: licking ? 1.08 : 0.96, anchor: .bottom)
      .rotationEffect(.degrees(licking ? 4 : -3), anchor: .bottom)
      .animation(.easeInOut(duration: 0.32).repeatForever(autoreverses: true), value: licking)
      .onAppear { licking = true }
      .accessibilityHidden(true)
  }
}
