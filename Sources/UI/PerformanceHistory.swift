import Charts
import SwiftUI

/// Every reply this iPhone has written, plotted. The measurements are the ones already kept
/// alongside each reply, so the history is as long as the chats that are still saved and needs
/// nothing recorded on the side.
///
/// Reachable from the developer screen, which is the development app only.
struct PerformanceHistory: View {
  let chat: ChatModel

  @State private var metric = Metric.decodeSpeed

  /// What can be plotted, and how to read it off a reply.
  enum Metric: String, CaseIterable, Identifiable {
    case decodeSpeed = "Speed"
    case firstToken = "First token"
    case memory = "Memory"

    var id: Self { self }

    var title: String {
      switch self {
      case .decodeSpeed: "Decode speed"
      case .firstToken: "Time to first token"
      case .memory: "Peak app memory"
      }
    }

    var axisLabel: String {
      switch self {
      case .decodeSpeed: "tok/s"
      case .firstToken: "seconds"
      case .memory: "MB"
      }
    }

    /// What the reading means when it goes up. Decode speed is the one metric where higher is the
    /// good direction, which is what the summary rows call "Best".
    var higherIsBetter: Bool { self == .decodeSpeed }

    func value(_ stats: ReplyStats) -> Double? {
      switch self {
      case .decodeSpeed: stats.decodeTokensPerSecond
      case .firstToken: stats.timeToFirstToken
      case .memory: stats.peakMemoryBytes.map { Double($0) / 1_048_576 }
      }
    }

    func format(_ value: Double) -> String {
      switch self {
      case .decodeSpeed: String(format: "%.1f tok/s", value)
      case .firstToken: String(format: "%.2f s", value)
      case .memory: String(format: "%.0f MB", value)
      }
    }
  }

  /// One reply, numbered oldest first so the chart reads left to right in the order they happened.
  struct Point: Identifiable {
    let id: UUID
    let number: Int
    let date: Date
    let stats: ReplyStats
  }

  var body: some View {
    List {
      if points.isEmpty {
        Section {
          Text(
            "No replies measured yet. Every reply records its own speed and memory; they show up "
              + "here as soon as there are some, and last as long as the chats they belong to."
          )
          .foregroundStyle(.secondary)
        }
      } else {
        Section {
          Picker("Metric", selection: $metric) {
            ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          .listRowSeparator(.hidden)

          chart
            .frame(height: 220)
            .listRowSeparator(.hidden)
        } header: {
          Text(metric.title)
        } footer: {
          Text(
            "\(values.count) of \(points.count) replies reported this. Oldest on the left; the "
              + "dashed line is the average.")
        }

        summarySection
        recentSection
      }
    }
    .navigationTitle("Reply history")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  // MARK: - The chart

  private var chart: some View {
    Chart {
      ForEach(plotted) { point in
        LineMark(
          x: .value("Reply", point.number),
          y: .value(metric.axisLabel, metric.value(point.stats) ?? 0)
        )
        .interpolationMethod(.monotone)
        .foregroundStyle(ChatStyle.sendFill)

        PointMark(
          x: .value("Reply", point.number),
          y: .value(metric.axisLabel, metric.value(point.stats) ?? 0)
        )
        .symbolSize(plotted.count > 40 ? 6 : 22)
        .foregroundStyle(ChatStyle.sendFill)
      }
      if let average {
        RuleMark(y: .value("Average", average))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .foregroundStyle(.secondary)
      }
    }
    .chartYAxisLabel(metric.axisLabel)
    .chartXAxisLabel("Reply")
  }

  // MARK: - The numbers under it

  private var summarySection: some View {
    Section("Summary") {
      LabeledContent("Replies measured", value: values.count.formatted())
      if let average { LabeledContent("Average", value: metric.format(average)) }
      if let best = metric.higherIsBetter ? values.max() : values.min() {
        LabeledContent("Best", value: metric.format(best))
      }
      if let worst = metric.higherIsBetter ? values.min() : values.max() {
        LabeledContent("Worst", value: metric.format(worst))
      }
      if let last = values.last { LabeledContent("Latest", value: metric.format(last)) }
    }
  }

  /// The last few replies in full, newest first — the chart says how things are trending, this says
  /// what actually happened.
  private var recentSection: some View {
    Section("Latest replies") {
      ForEach(points.suffix(12).reversed()) { point in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text(metric.value(point.stats).map(metric.format) ?? "—")
              .font(.body.weight(.medium))
            Spacer()
            Text(point.date.formatted(date: .abbreviated, time: .shortened))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          Text(
            "\(MetricFormat.count(point.stats.replyTokens)) tokens · \(point.stats.producedBy) · "
              + MetricFormat.seconds(point.stats.totalSeconds)
              + (point.stats.wasStopped ? " · stopped early" : "")
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
      }
    }
  }

  // MARK: - Where the history comes from

  /// Every measured reply in every chat that is still saved, oldest first. The chat that is open
  /// is included on its own: it only joins `savedChats` once it has been written to disk.
  private var points: [Point] {
    var chats = chat.savedChats
    if !chats.contains(where: { $0.id == chat.openChat.id }) { chats.append(chat.openChat) }
    let measured =
      chats
      .flatMap(\.messages)
      .filter { $0.stats != nil }
      .sorted { $0.createdAt < $1.createdAt }
    return measured.enumerated().map { index, message in
      Point(id: message.id, number: index + 1, date: message.createdAt, stats: message.stats!)
    }
  }

  /// Only the replies that reported the metric being shown; the rest would plot as a hole.
  private var plotted: [Point] { points.filter { metric.value($0.stats) != nil } }

  private var values: [Double] { plotted.compactMap { metric.value($0.stats) } }

  private var average: Double? {
    values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
  }
}
