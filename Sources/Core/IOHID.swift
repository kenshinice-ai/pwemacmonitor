import Foundation
import IOKit

/// IOHID temperature sensors (private IOHIDEventSystemClient API inside IOKit).
/// On Apple Silicon this exposes CPU/GPU die sensors, NAND (SSD) temps, battery, PMU, etc.
///
/// The client and its service list are created once and reused. Rebuilding them per sample —
/// the obvious implementation — measured 55 ms a call on an M4 Max, which made it the single most
/// expensive source in the app; reusing them costs a fraction of that.
final class IOHIDSensors {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloat = @convention(c) (CFTypeRef, Int64) -> Double

    private let fCreate: ClientCreate, fMatch: SetMatching, fServices: CopyServices
    private let fProp: CopyProperty, fEvent: CopyEvent, fFloat: GetFloat
    private let matching: CFDictionary
    private static let eventTypeTemperature: Int64 = 15

    private var client: CFTypeRef?
    /// (service, product name) pairs, resolved once — the name lookup is a CF copy per service.
    private var services: [(CFTypeRef, String)] = []
    private var servicesLoadedAt: TimeInterval = 0

    init?() {
        guard let lib = DynamicLibrary("/System/Library/Frameworks/IOKit.framework/IOKit"),
              let c = lib.symbol("IOHIDEventSystemClientCreate", as: ClientCreate.self),
              let m = lib.symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let s = lib.symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let p = lib.symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let e = lib.symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let f = lib.symbol("IOHIDEventGetFloatValue", as: GetFloat.self) else { return nil }
        fCreate = c; fMatch = m; fServices = s; fProp = p; fEvent = e; fFloat = f
        matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005] as CFDictionary
        loadServices()
        if services.isEmpty { return nil }
    }

    private func loadServices() {
        guard let c = fCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        _ = fMatch(c, matching)
        guard let list = fServices(c)?.takeRetainedValue() as? [CFTypeRef] else { return }
        var out: [(CFTypeRef, String)] = []
        out.reserveCapacity(list.count)
        for svc in list {
            guard let name = fProp(svc, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
            out.append((svc, name))
        }
        client = c                    // held so the services stay valid
        services = out
        servicesLoadedAt = ProcessInfo.processInfo.systemUptime
    }

    /// Sensors come and go (an external display, a disconnected battery), so the list is rebuilt
    /// occasionally rather than never.
    private func refreshIfStale() {
        if ProcessInfo.processInfo.systemUptime - servicesLoadedAt > 60 { loadServices() }
    }

    /// Names of every temperature service on this machine.
    var sensorNames: [String] { services.map(\.1) }

    /// Read temperatures. `only` restricts the sweep to the named sensors — each reading costs a
    /// CoreFoundation event copy (~0.22 ms), so a full sweep of ~200 services is ~45 ms and is worth
    /// avoiding unless the caller genuinely wants them all.
    func temperatures(only wanted: Set<String>? = nil) -> [(name: String, celsius: Double)] {
        refreshIfStale()
        var out: [(String, Double)] = []
        out.reserveCapacity(wanted?.count ?? services.count)
        for (svc, name) in services {
            if let wanted, !wanted.contains(name) { continue }
            guard let ev = fEvent(svc, Self.eventTypeTemperature, 0, 0)?.takeRetainedValue() else { continue }
            let t = fFloat(ev, Self.eventTypeTemperature << 16)
            if t > 0, t <= 150 { out.append((name, t)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
