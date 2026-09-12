import Darwin
import Foundation
import Metal
import os

/// Point-in-time resource readings for this app.
///
/// iOS doesn't let an app read GPU utilization, so the GPU figure here is the Metal memory this
/// process has allocated, not how busy the GPU is.
struct DeviceSnapshot: Sendable {
  var memoryFootprint: UInt64?
  var availableMemory: UInt64?
  var gpuMemory: UInt64?
  var cpuPercent: Double?
  var thermalState: ProcessInfo.ThermalState
}

struct PeakUsage: Sendable {
  var memory: UInt64?
  var cpuPercent: Double?
}

enum DeviceMetrics {
  private static let metalDevice = MTLCreateSystemDefaultDevice()

  static func snapshot() -> DeviceSnapshot {
    DeviceSnapshot(
      memoryFootprint: memoryFootprint(),
      availableMemory: availableMemory(),
      gpuMemory: gpuMemory(),
      cpuPercent: cpuPercent(),
      thermalState: ProcessInfo.processInfo.thermalState)
  }

  /// The footprint iOS compares against the app's memory limit — what Xcode's memory gauge shows.
  static func memoryFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
  }

  /// How much more memory the app can use before iOS terminates it.
  static func availableMemory() -> UInt64? {
    let bytes = os_proc_available_memory()
    return bytes > 0 ? UInt64(bytes) : nil
  }

  static func gpuMemory() -> UInt64? {
    metalDevice.map { UInt64($0.currentAllocatedSize) }
  }

  /// Summed across every non-idle thread, so 200% means two cores are fully busy.
  static func cpuPercent() -> Double? {
    var threadList: thread_act_array_t?
    var threadCount = mach_msg_type_number_t(0)
    guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
      let threadList
    else { return nil }
    defer {
      for index in 0..<Int(threadCount) {
        mach_port_deallocate(mach_task_self_, threadList[index])
      }
      vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: threadList)),
        vm_size_t(MemoryLayout<thread_t>.stride * Int(threadCount)))
    }

    var total = 0.0
    for index in 0..<Int(threadCount) {
      var info = thread_basic_info()
      var count = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
      let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
      }
      guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
      total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
    }
    return total
  }

  /// Samples memory and CPU until cancelled, then reports the highest readings it saw.
  static func monitorPeaks(every interval: Duration = .milliseconds(500)) -> Task<PeakUsage, Never> {
    Task.detached(priority: .utility) {
      var peak = PeakUsage()
      repeat {
        if let memory = memoryFootprint() { peak.memory = max(peak.memory ?? 0, memory) }
        if let cpu = cpuPercent() { peak.cpuPercent = max(peak.cpuPercent ?? 0, cpu) }
        try? await Task.sleep(for: interval)
      } while !Task.isCancelled
      return peak
    }
  }
}

extension ProcessInfo.ThermalState {
  var label: String {
    switch self {
    case .nominal: "Normal"
    case .fair: "Fair"
    case .serious: "Serious (throttling)"
    case .critical: "Critical"
    @unknown default: "Unknown"
    }
  }
}

extension Duration {
  var inSeconds: Double {
    let parts = components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }
}

/// Shared formatting for numbers on the metrics screens, so an unknown value always reads the same.
enum MetricFormat {
  static func bytes(_ value: UInt64?) -> String {
    value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—"
  }

  static func count(_ value: Int?) -> String {
    value.map { $0.formatted() } ?? "—"
  }

  static func rate(_ value: Double?) -> String {
    value.map { String(format: "%.1f tok/s", $0) } ?? "—"
  }

  static func seconds(_ value: Double?) -> String {
    value.map { String(format: "%.2f s", $0) } ?? "—"
  }

  static func percent(_ value: Double?) -> String {
    value.map { String(format: "%.0f%%", $0) } ?? "—"
  }
}
