import Foundation
import IOKit
import IOKit.ps

struct MemoryStats {
    var total: UInt64 = 0, used: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, cached: UInt64 = 0
    var app: UInt64 = 0
    var swapTotal: UInt64 = 0, swapUsed: UInt64 = 0
    var pressure: Int = 100   // kern.memorystatus_level: 100 = no pressure
    var usedRatio: Double { zeroDiv(Double(used), Double(total)) }

    static func read() -> MemoryStats {
        var m = MemoryStats()
        m.total = sysctlValue("hw.memsize", UInt64.self) ?? 0
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if rc == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let active = UInt64(stats.active_count), inactive = UInt64(stats.inactive_count)
            let wired = UInt64(stats.wire_count), spec = UInt64(stats.speculative_count)
            let comp = UInt64(stats.compressor_page_count), purg = UInt64(stats.purgeable_count)
            let ext = UInt64(stats.external_page_count), internalPages = UInt64(stats.internal_page_count)
            m.used = (active + inactive + wired + spec + comp).subtracting(purg + ext) * page
            m.wired = wired * page
            m.compressed = comp * page
            m.cached = ext * page
            m.app = internalPages.subtracting(purg) * page
        }
        if let sw = sysctlValue("vm.swapusage", xsw_usage.self) { m.swapTotal = sw.xsu_total; m.swapUsed = sw.xsu_used }
        m.pressure = Int(sysctlValue("kern.memorystatus_level", Int32.self) ?? 100)
        return m
    }
}

private extension UInt64 { func subtracting(_ o: UInt64) -> UInt64 { self > o ? self - o : 0 } }

struct DiskStats {
    var name = ""
    var total: UInt64 = 0, free: UInt64 = 0
    var readBytes: UInt64 = 0, writeBytes: UInt64 = 0    // cumulative
    var usedRatio: Double { zeroDiv(Double(total - free), Double(total)) }

    /// Volume capacity barely moves and the query is the expensive half of this struct, so it is
    /// cached; the byte counters are cheap and read every sample.
    private static var cachedCapacity: (total: UInt64, free: UInt64, at: TimeInterval) = (0, 0, -1e9)
    private static var cachedName = ""

    static func read() -> DiskStats {
        var d = DiskStats()
        let now = ProcessInfo.processInfo.systemUptime
        if now - cachedCapacity.at > 20 {
            var total: UInt64 = 0, free: UInt64 = 0
            cachedName = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? ""
            if let a = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
                total = (a[.systemSize] as? NSNumber)?.uint64Value ?? 0
                free = (a[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            }
            // APFS: prefer the "important" free space, which is what Finder reports.
            if let u = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let v = u.volumeAvailableCapacityForImportantUsage, v > 0 { free = UInt64(v) }
            cachedCapacity = (total, free, now)
        }
        d.total = cachedCapacity.total
        d.free = cachedCapacity.free
        d.name = cachedName

        if var it = IOServiceIterator("IOBlockStorageDriver") {
            while let (entry, _) = it.next() {
                defer { IOObjectRelease(entry) }
                guard let p = ioProperties(entry), let s = p["Statistics"] as? [String: Any] else { continue }
                d.readBytes += (s["Bytes (Read)"] as? UInt64) ?? 0
                d.writeBytes += (s["Bytes (Write)"] as? UInt64) ?? 0
            }
        }
        return d
    }
}

struct NetworkStats {
    var inBytes: UInt64 = 0, outBytes: UInt64 = 0   // cumulative (32-bit counters summed, wrap handled by caller)
    /// Interface carrying the most traffic, with its IPv4 address — a good enough stand-in for
    /// "the connection you are actually using" without pulling in SystemConfiguration.
    var primaryInterface = "", primaryAddress = ""

    static func read() -> NetworkStats {
        var n = NetworkStats()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return n }
        defer { freeifaddrs(ifap) }

        var busiest = (name: "", bytes: UInt64(0))
        var addresses: [String: String] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("lo") || name.hasPrefix("gif") || name.hasPrefix("stf") { continue }
            guard let addr = ifa.ifa_addr else { continue }

            if addr.pointee.sa_family == UInt8(AF_INET), addresses[name] == nil {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name] = String(cString: host)
                }
                continue
            }
            guard addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            n.inBytes += UInt64(d.ifi_ibytes); n.outBytes += UInt64(d.ifi_obytes)
            let total = UInt64(d.ifi_ibytes) + UInt64(d.ifi_obytes)
            if total > busiest.bytes { busiest = (name, total) }
        }
        n.primaryInterface = busiest.name
        n.primaryAddress = addresses[busiest.name] ?? ""
        return n
    }
}

struct BatteryStats {
    var present = false
    var percent = 0, isCharging = false, externalPower = false
    var temperature = 0.0, cycles = 0, health = 0.0   // health = max/design
    var watts = 0.0                                    // +charging / -discharging
    var timeRemainingMin: Int? = nil

    static func read() -> BatteryStats {
        var b = BatteryStats()
        guard let p = ioFirstProperties("AppleSmartBattery") else { return b }
        b.present = true
        b.percent = p["CurrentCapacity"] as? Int ?? 0
        b.isCharging = p["IsCharging"] as? Bool ?? false
        b.externalPower = p["ExternalConnected"] as? Bool ?? false
        if let t = p["Temperature"] as? Int { b.temperature = Double(t) / 100 }
        b.cycles = p["CycleCount"] as? Int ?? 0
        // A fresh pack routinely measures a little above its design capacity; report that as 100 %
        // rather than "101 %", which reads as a bug. Newer macOS drops AppleRawMaxCapacity, so fall
        // back to the nominal charge capacity.
        let maxCapacity = (p["AppleRawMaxCapacity"] as? Int) ?? (p["NominalChargeCapacity"] as? Int)
        if let mx = maxCapacity, let design = p["DesignCapacity"] as? Int, design > 0 {
            b.health = min(1.0, Double(mx) / Double(design))
        }
        if let mA = p["Amperage"] as? Int, let mV = p["Voltage"] as? Int {
            let amps = Double(Int64(truncatingIfNeeded: mA)) / 1000
            b.watts = amps * Double(mV) / 1000
        }
        if let t = p["TimeRemaining"] as? Int, t > 0, t < 65535 { b.timeRemainingMin = t }
        return b
    }
}

struct ProcessStat: Identifiable {
    let pid: Int32, name: String
    var cpuPercent: Double, memoryBytes: UInt64
    var id: Int32 { pid }
}

/// Top processes by CPU (Activity Monitor style) using libproc rusage deltas.
final class ProcessSampler {
    private var prevTimes: [Int32: (UInt64, TimeInterval)] = [:]
    private let timebase: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    /// Drop the accumulated CPU-time baseline; the next sample starts a fresh interval.
    func reset() { prevTimes.removeAll(keepingCapacity: true) }

    func sample() -> [ProcessStat] {
        let now = ProcessInfo.processInfo.systemUptime
        var n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) / MemoryLayout<pid_t>.size + 64)
        n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let count = Int(n) / MemoryLayout<pid_t>.size
        var out: [ProcessStat] = []
        var seen = Set<Int32>()
        for pid in pids.prefix(count) where pid > 0 {
            var ru = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ru) { p -> Int32 in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard rc == 0 else { continue }
            seen.insert(pid)
            let total = ru.ri_user_time &+ ru.ri_system_time   // mach absolute units
            var cpu = 0.0
            if let (pt, ptime) = prevTimes[pid], now > ptime, total >= pt {
                cpu = Double(total - pt) * timebase / 1e9 / (now - ptime) * 100
            }
            prevTimes[pid] = (total, now)
            var nameBuf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            let name = String(cString: nameBuf)
            out.append(ProcessStat(pid: pid, name: name.isEmpty ? "pid \(pid)" : name, cpuPercent: cpu, memoryBytes: ru.ri_phys_footprint))
        }
        prevTimes = prevTimes.filter { seen.contains($0.key) }
        return out
    }
}
