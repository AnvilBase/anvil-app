import SwiftUI

/// Live device readings, what the loaded model can do, the latest reply's measurements, and the
/// running totals. Every reading has a sentence under it saying what it means.
struct MetricsScreen: View {
  let chat: ChatModel

  @State private var snapshot = DeviceMetrics.snapshot()
  @State private var confirmingReset = false

  var body: some View {
    List {
      Section("Live") {
        metricRow(
          "App memory", MetricFormat.bytes(snapshot.memoryFootprint),
          detail: "What iOS counts against this app's memory limit.")
        metricRow(
          "Memory left before iOS limit", MetricFormat.bytes(snapshot.availableMemory),
          detail:
            "How much more the app can use before iOS closes it. If it nears zero, lower the "
            + "context size or turn off image input.")
        metricRow(
          "GPU (Metal) memory", MetricFormat.bytes(snapshot.gpuMemory),
          detail:
            "The part of app memory set aside for the GPU, not extra memory. iOS doesn't let apps "
            + "see how busy the GPU is.")
        metricRow(
          "CPU", MetricFormat.percent(snapshot.cpuPercent),
          detail: "Summed across cores, so 200% means two cores are busy.")
        LabeledContent("Thermal state", value: snapshot.thermalState.label)
      }

      if let details = chat.modelDetails {
        modelSection(details)
      }

      Section("Current chat") {
        if let used = chat.contextTokens, let limit = chat.modelDetails?.contextSize {
          LabeledContent("Context used", value: "\(used.formatted()) / \(limit.formatted()) tokens")
          ProgressView(value: Double(min(used, limit)), total: Double(limit))
        } else {
          Text("Send a message to see how much of the context this chat uses.")
            .foregroundStyle(.secondary)
        }
        if let stats = chat.messages.last(where: { $0.stats != nil })?.stats {
          NavigationLink("Last reply") {
            List { ReplyStatsRows(stats: stats) }
              .navigationTitle("Last reply")
          }
        }
      }

      totalsSection
    }
    .navigationTitle("Performance and usage")
    .task {
      while !Task.isCancelled {
        snapshot = DeviceMetrics.snapshot()
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .confirmationDialog("Reset totals?", isPresented: $confirmingReset, titleVisibility: .visible) {
      Button("Reset", role: .destructive) { chat.resetTotals() }
    }
  }

  /// A reading with its explanation underneath.
  private func metricRow(_ title: String, _ value: String, detail: String) -> some View {
    LabeledContent {
      Text(value)
    } label: {
      Text(title)
      Text(detail)
    }
  }

  private func modelSection(_ details: ModelDetails) -> some View {
    Section("Model") {
      LabeledContent("File", value: details.fileName)
      LabeledContent(
        "Size", value: ByteCountFormatter.string(fromByteCount: details.fileSize, countStyle: .file))
      LabeledContent("Backend", value: details.backend)
      LabeledContent("Image input", value: details.imageBackend.map { "On (\($0))" } ?? "Off")
      LabeledContent("Context size", value: "\(details.contextSize.formatted()) tokens")
      LabeledContent("Load time", value: MetricFormat.seconds(details.loadSeconds))
      LabeledContent("Thinking", value: details.supportsThinking ? "Supported" : "Not supported")
      LabeledContent("Tool calling", value: details.supportsToolCalling ? "Supported" : "Not supported")
      LabeledContent("Audio input", value: details.supportsAudio ? "Supported" : "Not supported")
      LabeledContent(
        "Default sampling", value: details.defaultSampler.map(Self.describe) ?? "Not specified")
    }
  }

  private var totalsSection: some View {
    Section {
      LabeledContent("Replies", value: chat.totals.replies.formatted())
      LabeledContent("Prompt tokens", value: chat.totals.promptTokens.formatted())
      LabeledContent("Reply tokens", value: chat.totals.replyTokens.formatted())
      LabeledContent("Average decode speed", value: MetricFormat.rate(chat.totals.averageDecodeSpeed))
      LabeledContent(
        "Average time to first token",
        value: MetricFormat.seconds(chat.totals.averageTimeToFirstToken))
      Button("Reset totals", role: .destructive) { confirmingReset = true }
    } header: {
      Text("All replies")
    } footer: {
      Text(
        "Since \(chat.totals.since.formatted(date: .abbreviated, time: .shortened)). Totals are "
          + "kept when chats are deleted.")
    }
  }

  private static func describe(_ sampler: SamplerValues) -> String {
    String(
      format: "temp %.2f · top-K %d · top-P %.2f", sampler.temperature, sampler.topK, sampler.topP)
  }
}

/// The full breakdown for one reply, opened from the caption under it.
struct ReplyStatsSheet: View {
  let stats: ReplyStats

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List { ReplyStatsRows(stats: stats) }
        .navigationTitle("Reply metrics")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
    .presentationDetents([.medium, .large])
  }
}

struct ReplyStatsRows: View {
  let stats: ReplyStats

  var body: some View {
    Section("Tokens") {
      LabeledContent("Prompt (prefill)", value: MetricFormat.count(stats.promptTokens))
      LabeledContent("Reply (decode)", value: MetricFormat.count(stats.replyTokens))
      LabeledContent(
        "Context after reply",
        value: stats.contextTokens.map { "\($0.formatted()) / \(stats.contextLimit.formatted())" }
          ?? "—")
    }
    Section("Speed") {
      LabeledContent("Time to first token", value: MetricFormat.seconds(stats.timeToFirstToken))
      LabeledContent("Prefill speed", value: MetricFormat.rate(stats.prefillTokensPerSecond))
      LabeledContent("Decode speed", value: MetricFormat.rate(stats.decodeTokensPerSecond))
      LabeledContent("Total time", value: MetricFormat.seconds(stats.totalSeconds))
    }
    Section {
      LabeledContent("Produced by", value: stats.producedBy)
      LabeledContent("Peak app memory", value: MetricFormat.bytes(stats.peakMemoryBytes))
      LabeledContent("GPU (Metal) memory", value: MetricFormat.bytes(stats.gpuMemoryBytes))
      LabeledContent("Peak CPU", value: MetricFormat.percent(stats.peakCPUPercent))
      LabeledContent("Thermal state", value: stats.thermalState)
    } header: {
      Text("Device")
    } footer: {
      if stats.wasStopped {
        Text("This reply was stopped early.")
      } else if stats.replyTokens == nil {
        Text("The engine didn't report token counts for this reply.")
      }
    }
  }
}
