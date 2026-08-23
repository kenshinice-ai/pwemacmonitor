import Foundation

/// Port of macmon's IOReport sampler (private libIOReport.dylib, loaded via dlopen so it
/// works on any Apple Silicon Mac without an SDK .tbd).
final class IOReport {
    struct Channel {
        let group: String, subgroup: String, name: String, unit: String
        let item: CFDictionary
    }
    struct Sample {
        let channels: [Channel]
        let elapsed: TimeInterval
        private let keepAlive: CFDictionary
        init(channels: [Channel], elapsed: TimeInterval, keepAlive: CFDictionary) {
            self.channels = channels; self.elapsed = elapsed; self.keepAlive = keepAlive
        }
    }

    private typealias CopyAllChannels = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> UnsafeRawPointer?
    private typealias CreateSamples = @convention(c) (UnsafeRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetInteger = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let lib: DynamicLibrary
    private let fCreateSamples: CreateSamples
    private let fDelta: CreateSamplesDelta
    private let fGroup: GetString, fSubgroup: GetString, fChannelName: GetString, fUnit: GetString
    private let fInteger: GetInteger
    private let fStateCount: StateCount, fStateName: StateName, fStateResidency: StateResidency

    private let channels: CFMutableDictionary
    private let subscription: UnsafeRawPointer
    private var prev: (CFDictionary, TimeInterval)?

    static func channelFilter(group: String, subgroup: String, channel: String) -> Bool {
        if group == "Energy Model" {
            return channel == "GPU Energy" || channel.hasSuffix("CPU Energy")
                || channel.hasPrefix("ANE") || channel.hasPrefix("DRAM") || channel.hasPrefix("GPU SRAM")
        }
        if group == "CPU Stats" { return subgroup == "CPU Core Performance States" }
        return group == "GPU Stats" && subgroup == "GPU Performance States"
    }

    init?() {
        guard let lib = DynamicLibrary("/usr/lib/libIOReport.dylib") ?? DynamicLibrary("libIOReport.dylib"),
              let copyAll = lib.symbol("IOReportCopyAllChannels", as: CopyAllChannels.self),
              let createSub = lib.symbol("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = lib.symbol("IOReportCreateSamples", as: CreateSamples.self),
              let delta = lib.symbol("IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
              let group = lib.symbol("IOReportChannelGetGroup", as: GetString.self),
              let subgroup = lib.symbol("IOReportChannelGetSubGroup", as: GetString.self),
              let channelName = lib.symbol("IOReportChannelGetChannelName", as: GetString.self),
              let unit = lib.symbol("IOReportChannelGetUnitLabel", as: GetString.self),
              let integer = lib.symbol("IOReportSimpleGetIntegerValue", as: GetInteger.self),
              let stateCount = lib.symbol("IOReportStateGetCount", as: StateCount.self),
              let stateName = lib.symbol("IOReportStateGetNameForIndex", as: StateName.self),
              let stateRes = lib.symbol("IOReportStateGetResidency", as: StateResidency.self)
        else { return nil }

        self.lib = lib
        fCreateSamples = createSamples; fDelta = delta
        fGroup = group; fSubgroup = subgroup; fChannelName = channelName; fUnit = unit
        fInteger = integer; fStateCount = stateCount; fStateName = stateName; fStateResidency = stateRes

        guard let all = copyAll(0, 0)?.takeRetainedValue() as NSDictionary?,
              let array = all["IOReportChannels"] as? [NSDictionary] else { return nil }

        let selected = NSMutableArray()
        for item in array {
            let cf = item as CFDictionary
            let g = Self.str(group(cf)), s = Self.str(subgroup(cf)), c = Self.str(channelName(cf))
            if Self.channelFilter(group: g, subgroup: s, channel: c) { selected.add(item) }
        }
        guard selected.count > 0 else { return nil }
        let chan = NSMutableDictionary(dictionary: all)
        chan["IOReportChannels"] = selected
        channels = chan as CFMutableDictionary

        var subDict: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, channels, &subDict, 0, nil) else { return nil }
        subscription = sub
    }

    private static func str(_ u: Unmanaged<CFString>?) -> String {
        guard let u else { return "" }
        return (u.takeUnretainedValue() as String).trimmingCharacters(in: .whitespaces)
    }

    private func raw() -> (CFDictionary, TimeInterval)? {
        guard let s = fCreateSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        return (s, ProcessInfo.processInfo.systemUptime)
    }

    /// Returns the delta since the previous call (nil on the very first call, which just primes the baseline).
    func sampleSincePrevious() -> Sample? {
        guard let next = raw() else { return nil }
        defer { prev = next }
        guard let p = prev else { return nil }
        guard let diff = fDelta(p.0, next.0, nil)?.takeRetainedValue() as NSDictionary?,
              let array = diff["IOReportChannels"] as? [NSDictionary] else { return nil }
        let elapsed = max(next.1 - p.1, 1e-6)
        let chans = array.map { item -> Channel in
            let cf = item as CFDictionary
            return Channel(group: Self.str(fGroup(cf)), subgroup: Self.str(fSubgroup(cf)),
                           name: Self.str(fChannelName(cf)), unit: Self.str(fUnit(cf)), item: cf)
        }
        return Sample(channels: chans, elapsed: elapsed, keepAlive: diff as CFDictionary)
    }

    func residencies(_ item: CFDictionary) -> [(String, Int64)] {
        (0..<fStateCount(item)).map { i in
            let name = fStateName(item, i).map { $0.takeUnretainedValue() as String } ?? "S\(i)"
            return (name, fStateResidency(item, i))
        }
    }

    func watts(_ ch: Channel, elapsed: TimeInterval) -> Double {
        let v = Double(fInteger(ch.item, 0)) / elapsed
        switch ch.unit {
        case "mJ": return v / 1e3
        case "uJ": return v / 1e6
        case "nJ": return v / 1e9
        default: return 0
        }
    }
}
