#if ANVIL_DEV
  import Foundation

  /// The phone's temperature in degrees, read from the sensors iOS itself watches — when iOS
  /// lets the app read them, which is not promised.
  ///
  /// There is no public way to ask an iPhone how hot it is; the public answer is the four-band
  /// thermal state. The sensors are behind IOKit's HID event system, which the app reaches by
  /// name with `dlsym` rather than by linking anything, and iOS may hand back no sensors at all
  /// on a given build. Every reading here is a "maybe", and the line that shows it says the band
  /// instead when the answer is no.
  ///
  /// Development app only, and not by choice: a private interface in the public app is a
  /// rejection at review, so the public build never compiles this.
  enum DeviceTemperature {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias FloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    /// HID usage page and usage for Apple's temperature sensors, and the event type and field
    /// their readings come back on.
    private static let vendorUsagePage = 0xff00
    private static let temperatureUsage = 5
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
      guard let iokit, let pointer = dlsym(iokit, name) else { return nil }
      return unsafeBitCast(pointer, to: T.self)
    }

    private static let create = symbol("IOHIDEventSystemClientCreate", as: ClientCreate.self)
    private static let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self)
    private static let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self)
    private static let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self)
    private static let floatValue = symbol("IOHIDEventGetFloatValue", as: FloatValue.self)

    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private static let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self)

    /// Every sensor by name with its reading: the battery gauge, the PMU's dies and devices, the
    /// NAND, the charger. `celsius` picks the one that answers the question.
    static func readings() -> [(name: String, celsius: Double)] {
      guard let create, let setMatching, let copyServices, let copyEvent, let floatValue,
        let copyProperty, let client = create(kCFAllocatorDefault)?.takeRetainedValue()
      else { return [] }
      setMatching(client, ["PrimaryUsagePage": vendorUsagePage, "PrimaryUsage": temperatureUsage] as CFDictionary)
      guard let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
      return services.compactMap { service in
        let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
        guard let event = copyEvent(service, temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
        return (name, floatValue(event, temperatureField))
      }
    }

    /// The battery's temperature in degrees Celsius, or nil when the phone won't say. The
    /// battery rather than the hottest sensor: the chip dies run twenty degrees above it under
    /// no load at all, and the charger sensors are the cable, whereas the battery is the slab
    /// that is the phone in the hand — what a person means by how hot the phone is.
    static func celsius() -> Double? {
      let all = readings()
      let battery =
        all.first { $0.name == "gas gauge battery" } ?? all.first { $0.name.localizedCaseInsensitiveContains("battery") }
      guard let battery, battery.celsius > 0, battery.celsius < 100 else { return nil }
      return battery.celsius
    }

    static func fahrenheit() -> Double? {
      celsius().map { $0 * 9 / 5 + 32 }
    }
  }
#endif
