import Foundation
import IOKit
import IOKit.ps

/// macOS's own verdict on memory, the three levels Activity Monitor's pressure graph is drawn in.
///
/// Read from `kern.memorystatus_vm_pressure_level`, which answers 1, 2 or 4. The kernel decides
/// it from how much uncompressed memory is still available and whether the compressor has room —
/// **not** from how much is in use — and moves up and down across different lines, so the level
/// does not flap (xnu `vm_pageout.c`, `VM_PRESSURE_NORMAL_TO_WARNING` and its three siblings; on a
/// Mac with more than 3 GB the lines are 50 % and 34 % going up, 60 % and 40 % coming down).
///
/// Until 1.7.0 this app graded memory itself: "free" below 75 % was amber, below 45 % coral, and
/// anything over 85 % used was amber. Those were our numbers on quantities the kernel does not
/// use. Measured 2026-10-12: with the level set to warning and then to critical, free stayed at
/// 81–82 % and the old rule called all twenty seconds calm; and with used memory climbing from
/// 61 % to 77 % the level never left normal. See docs/thermal-verdict.md.
enum MemoryPressure: Int32, CaseIterable {
    case normal = 1, warning = 2, critical = 4

    var word: String {
        switch self {
        case .normal:   return L("pressure.normal", "Normal")
        case .warning:  return L("pressure.warning", "Warning")
        case .critical: return L("pressure.critical", "Critical")
        }
    }
    var health: Health {
        switch self {
        case .normal: return .calm
        case .warning: return .warm
        case .critical: return .hot
        }
    }
    /// For `--json`, which is never translated.
    var key: String { ["normal", "warning", "critical"][self == .normal ? 0 : self == .warning ? 1 : 2] }
}

struct MemoryStats {
    var total: UInt64 = 0, used: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, cached: UInt64 = 0
    var app: UInt64 = 0
    var swapTotal: UInt64 = 0, swapUsed: UInt64 = 0
    /// `kern.memorystatus_level`: available memory as a percentage of all of it. Higher is better.
    /// Kept for `--json`, where it has always been called `pressure`; nothing is graded on it.
    var pressure: Int = 100
    /// Nil when the level could not be read, or read as something other than 1, 2 or 4. That is
    /// "not known", and is drawn as a dash — never as a guess from the figures above.
    var level: MemoryPressure? = .normal
    /// What the sysctl answered, for diagnostics; -1 when it did not answer.
    var levelRaw: Int32 = 1
    /// Pages read back from swap and written out to it since boot. Each is counted as the bytes of
    /// that read or write over the page size (xnu `vm_compressor_backing_store.c`), so a difference
    /// times the page size is disk I/O.
    var swapIns: UInt64 = 0, swapOuts: UInt64 = 0
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
            m.swapIns = stats.swapins; m.swapOuts = stats.swapouts
        }
        if let sw = sysctlValue("vm.swapusage", xsw_usage.self) { m.swapTotal = sw.xsu_total; m.swapUsed = sw.xsu_used }
        m.pressure = Int(sysctlValue("kern.memorystatus_level", Int32.self) ?? 100)
        m.levelRaw = sysctlValue("kern.memorystatus_vm_pressure_level", Int32.self) ?? -1
        m.level = MemoryPressure(rawValue: m.levelRaw)
        return m
    }
}

private extension UInt64 { func subtracting(_ o: UInt64) -> UInt64 { self > o ? self - o : 0 } }

struct DiskStats {
    var name = ""
    var total: UInt64 = 0, free: UInt64 = 0
    var readBytes: UInt64 = 0, writeBytes: UInt64 = 0    // cumulative
    var usedRatio: Double { zeroDiv(Double(total - free), Double(total)) }

    /// Volume capacity barely moves and the query is the expensive half of this struct — the
    /// "important usage" figure is a round trip to the `deleted` daemon, about 20 ms each — so it
    /// is cached for a minute; the byte counters are cheap and read every sample.
    private static var cachedCapacity: (total: UInt64, free: UInt64, at: TimeInterval) = (0, 0, -1e9)
    private static var cachedName = ""

    static func read() -> DiskStats {
        var d = DiskStats()
        let now = ProcessInfo.processInfo.systemUptime
        if now - cachedCapacity.at > 60 {
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

        if let it = IOServiceIterator("IOBlockStorageDriver") {
            while let (entry, _) = it.next() {
                defer { IOObjectRelease(entry) }
                // The one key that is used, not the driver's whole property table: 0.13 ms
                // against 0.49 for the same two numbers.
                guard let s = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
                d.readBytes += (s["Bytes (Read)"] as? UInt64) ?? 0
                d.writeBytes += (s["Bytes (Write)"] as? UInt64) ?? 0
            }
        }
        return d
    }
}

struct NetworkStats {
    /// The link carrying the traffic, and its IPv4 address. See `NetworkSampler`.
    var primaryInterface = "", primaryAddress = ""
}

/// Throughput on the machine's physical links, and which of them is in use.
///
/// Three things the first version got wrong, all of them found by comparing it with `netstat -ib`
/// on 2026-10-09:
///
/// **The counters are 32 bits wide.** An unprivileged process is handed interface byte counts
/// truncated to 32 bits, whichever API it asks — `getifaddrs` and the `NET_RT_IFLIST2` sysctl
/// with its 64-bit fields return the same wrapped number. The Wi-Fi link had carried 118.6 GB and
/// read 2.6 GB. So a total is meaningless and only a difference can be trusted: taken per link,
/// in 32-bit arithmetic, where a wrap comes out right by itself (see `moved`). Summing first and subtracting
/// after, as before, printed a zero every time any one link passed a multiple of 4.29 GB.
///
/// **Tunnels were counted on top of the link they run over.** A VPN's `utun`, a relay's `anri`
/// and the bridge over the Thunderbolt ports all report the same bytes as the adapter underneath.
/// Only the adapters are counted now: Ethernet and Wi-Fi (`en`), the peer-to-peer Wi-Fi radio
/// that AirDrop and AirPlay use (`awdl`, `llw`), and cellular (`pdp_ip`).
///
/// **"The busiest link" was chosen by those wrapped totals**, which is to say at random among
/// the links that had ever been busy. It is chosen by what each link is carrying now, smoothed,
/// and it has to be clearly out-carried before it gives way.
final class NetworkSampler {
    struct Reading {
        var stats = NetworkStats()
        var inPerSec = 0.0, outPerSec = 0.0
    }

    private typealias Counters = (rx: UInt32, tx: UInt32, rxPackets: UInt32, txPackets: UInt32)
    private var previous: [String: Counters] = [:]
    private var previousTime: TimeInterval = 0
    /// Smoothed bytes per second, both directions, per link.
    private var activity: [String: Double] = [:]
    private var primary = ""

    static func counts(_ name: String) -> Bool {
        ["en", "awdl", "llw", "pdp_ip"].contains { name.hasPrefix($0) }
    }

    /// Bytes moved between two readings of a 32-bit counter.
    ///
    /// A counter that went backwards has either wrapped or been reset — an adapter re-attached
    /// under the same name starts again from nothing — and the byte count alone cannot say which.
    /// The packet counter can: it wraps once in several terabytes, so if it went backwards too
    /// the adapter was reset, and that sample counts as nothing. Otherwise the wrapping
    /// subtraction is already the right answer, however large.
    static func moved(from old: UInt32, to new: UInt32, packetsFrom oldPackets: UInt32, to newPackets: UInt32) -> UInt64 {
        if new >= old { return UInt64(new - old) }
        return newPackets < oldPackets ? 0 : UInt64(new &- old)
    }

    /// Which link to name. The one in use stays unless another carries twice as much and more
    /// than idle chatter, so two quiet links do not trade places every sample.
    static func choose(current: String, candidates: [String], activity: [String: Double]) -> String {
        guard !candidates.isEmpty else { return "" }
        // `max(by:)` keeps the first of equals, and the candidates arrive with routable
        // addresses ahead of self-assigned ones — so with nothing moving, the first real link.
        let busiest = candidates.max { (activity[$0] ?? 0) < (activity[$1] ?? 0) } ?? candidates[0]
        guard candidates.contains(current) else { return busiest }
        let mine = activity[current] ?? 0, theirs = activity[busiest] ?? 0
        return theirs > 4096 && theirs > mine * 2 ? busiest : current
    }

    func sample(now: TimeInterval) -> Reading {
        var r = Reading()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return r }
        defer { freeifaddrs(ifap) }

        var counters: [String: Counters] = [:]
        var addresses: [String: String] = [:]
        var order: [String] = [], bridges: [String] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            // A bridge is never counted — its members are — but on a Mac whose only network is
            // the Thunderbolt bridge it is the bridge that holds the address.
            let bridge = name.hasPrefix("bridge")
            guard Self.counts(name) || bridge, let addr = ifa.ifa_addr else { continue }

            if addr.pointee.sa_family == UInt8(AF_INET) {
                let up = Int32(ifa.ifa_flags) & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING)
                guard up, addresses[name] == nil else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name] = String(cString: host)
                    if bridge { bridges.append(name) } else { order.append(name) }
                }
            } else if !bridge, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = (d.ifi_ibytes, d.ifi_obytes, d.ifi_ipackets, d.ifi_opackets)
            }
        }

        let dt = now - previousTime
        if previousTime > 0, dt > 0 {
            var rx: UInt64 = 0, tx: UInt64 = 0
            for (name, c) in counters {
                // A link seen for the first time has no baseline; it starts counting next sample.
                guard let p = previous[name] else { continue }
                let i = Self.moved(from: p.rx, to: c.rx, packetsFrom: p.rxPackets, to: c.rxPackets)
                let o = Self.moved(from: p.tx, to: c.tx, packetsFrom: p.txPackets, to: c.txPackets)
                rx += i; tx += o
                activity[name] = (activity[name] ?? 0) * 0.7 + Double(i + o) / dt * 0.3
            }
            r.inPerSec = Double(rx) / dt
            r.outPerSec = Double(tx) / dt
        }
        activity = activity.filter { counters[$0.key] != nil }
        previous = counters
        previousTime = now

        // 169.254.x.x is an address a link gave itself for want of a network — a tethered phone,
        // a cable to nothing. It stays a candidate, behind every link with a real address; and a
        // bridge is named only when nothing else has an address at all.
        let candidates = order.filter { !(addresses[$0] ?? "").hasPrefix("169.254.") }
                       + order.filter { (addresses[$0] ?? "").hasPrefix("169.254.") }
                       + bridges
        primary = Self.choose(current: primary, candidates: candidates, activity: activity)
        r.stats.primaryInterface = primary
        r.stats.primaryAddress = addresses[primary] ?? ""
        return r
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
        //
        // macOS 27 moved the capacity figures off the top level into the nested `BatteryData`
        // dictionary. Reading only the top level found nothing, and the card reported a healthy
        // pack as 0 % — System Settings said 100 % on the same machine. Look in both places.
        let nested = p["BatteryData"] as? [String: Any]
        func capacity(_ key: String) -> Int? { (p[key] as? Int) ?? (nested?[key] as? Int) }
        let maxCapacity = capacity("AppleRawMaxCapacity") ?? capacity("NominalChargeCapacity")
        if let mx = maxCapacity, let design = capacity("DesignCapacity"), design > 0 {
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

    enum Order { case cpu, memory }

    /// The `limit` busiest processes since the previous call — or, by memory, the largest.
    ///
    /// Every process is asked for its CPU time — that is the cost, 3.8 ms for 1,500 of them on an
    /// efficiency core — but only the ones that make the list are asked for a name. The whole
    /// table is ordered before it is cut: the eight largest are not the eight busiest re-sorted.
    func top(_ limit: Int, by order: Order = .cpu) -> [ProcessStat] {
        let now = ProcessInfo.processInfo.systemUptime
        var n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) / MemoryLayout<pid_t>.size + 64)
        n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let count = Int(n) / MemoryLayout<pid_t>.size
        var usage: [(pid: Int32, cpu: Double, memory: UInt64)] = []
        usage.reserveCapacity(count)
        var times: [Int32: (UInt64, TimeInterval)] = [:]
        times.reserveCapacity(count)
        for pid in pids.prefix(count) where pid > 0 {
            var ru = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ru) { p -> Int32 in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard rc == 0 else { continue }
            let total = ru.ri_user_time &+ ru.ri_system_time   // mach absolute units
            var cpu = 0.0
            if let (pt, ptime) = prevTimes[pid], now > ptime, total >= pt {
                cpu = Double(total - pt) * timebase / 1e9 / (now - ptime) * 100
            }
            times[pid] = (total, now)
            usage.append((pid, cpu, ru.ri_phys_footprint))
        }
        prevTimes = times
        // The process ID breaks ties, so two idle processes of the same size do not trade rows.
        switch order {
        case .cpu:    usage.sort { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.pid < $1.pid }
        case .memory: usage.sort { $0.memory != $1.memory ? $0.memory > $1.memory : $0.pid < $1.pid }
        }
        return usage.prefix(limit).map { u in
            var nameBuf = [CChar](repeating: 0, count: 256)
            proc_name(u.pid, &nameBuf, UInt32(nameBuf.count))
            let name = String(cString: nameBuf)
            return ProcessStat(pid: u.pid, name: name.isEmpty ? "pid \(u.pid)" : name, cpuPercent: u.cpu, memoryBytes: u.memory)
        }
    }
}
