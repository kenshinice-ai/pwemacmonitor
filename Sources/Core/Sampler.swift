import Foundation

enum Health: Int, Comparable {
    case calm = 0, warm = 1, hot = 2
    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
    static func grade(_ v: Double, warm: Double, hot: Double) -> Health { v >= hot ? .hot : v >= warm ? .warm : .calm }
}

struct CoreMetric: Identifiable {
    let id: String          // IOReport channel name
    let isP: Bool
    var die: Int = 0, index: Int = 0
    var freqMHz: Int, scaled: Double, active: Double
    /// Human label for a tooltip: "3" on a single-die chip, "die 1 · 3" on an Ultra.
    var core_label: String { die > 0 ? "die \(die) · \(index)" : "\(index)" }
}

struct FanMetric: Identifiable {
    let id: String
    var rpm: Int, maxRPM: Int?
    var ratio: Double { maxRPM.map { zeroDiv(Double(rpm), Double($0)) } ?? 0 }
}

struct Sensor: Identifiable {
    /// Unique per snapshot: IOHID reports several services under the same product name
    /// (six "gas gauge battery" sensors on a MacBook Pro), and duplicate ids break SwiftUI lists.
    let id: String
    let name: String, value: Double, source: String
}

struct Snapshot {
    var time = Date()
    var interval = 2.0

    // CPU
    var cpuUsage = 0.0, cpuActive = 0.0          // 0–1 (frequency-scaled, and raw active)
    var ecpuFreq = 0, pcpuFreq = 0, ecpuUsage = 0.0, pcpuUsage = 0.0
    var cores: [CoreMetric] = []
    var loadAvg: (Double, Double, Double) = (0, 0, 0)
    // GPU
    var gpuUsage = 0.0, gpuActive = 0.0, gpuFreq = 0
    // Power (W)
    var cpuPower = 0.0, gpuPower = 0.0, anePower = 0.0, ramPower = 0.0, sysPower = 0.0
    var allPower: Double { cpuPower + gpuPower + anePower }
    // Thermals (°C)
    var cpuTemp = 0.0, cpuTempMax = 0.0, gpuTemp = 0.0, ssdTemp = 0.0, batteryTemp = 0.0
    var sensors: [Sensor] = []
    var fans: [FanMetric] = []
    // Memory / Disk / Net / Battery
    var memory = MemoryStats()
    var disk = DiskStats()
    var diskReadPerSec = 0.0, diskWritePerSec = 0.0
    var netInPerSec = 0.0, netOutPerSec = 0.0
    var network = NetworkStats()
    var battery = BatteryStats()
    var processes: [ProcessStat] = []
    var uptime: TimeInterval = 0

    // MARK: health grading (thresholds chosen to match Apple's own thermal envelopes)
    var cpuTempHealth: Health { Health.grade(cpuTemp, warm: 75, hot: 92) }
    /// The hottest core is what actually drives throttling, so it grades separately from the average.
    var cpuTempMaxHealth: Health { Health.grade(cpuTempMax, warm: 75, hot: 92) }
    var gpuTempHealth: Health { Health.grade(gpuTemp, warm: 75, hot: 92) }
    var ssdTempHealth: Health { ssdTemp == 0 ? .calm : Health.grade(ssdTemp, warm: 55, hot: 68) }
    var cpuLoadHealth: Health { Health.grade(cpuUsage, warm: 0.55, hot: 0.85) }
    var gpuLoadHealth: Health { Health.grade(gpuUsage, warm: 0.55, hot: 0.85) }
    var memoryHealth: Health {
        if memory.pressure < 45 { return .hot }
        if memory.pressure < 75 || memory.usedRatio > 0.85 { return .warm }
        return .calm
    }
    var diskHealth: Health { Health.grade(disk.usedRatio, warm: 0.85, hot: 0.95) }
    var fanHealth: Health { fans.map { Health.grade($0.ratio, warm: 0.45, hot: 0.8) }.max() ?? .calm }
    var batteryHealth: Health {
        guard battery.present else { return .calm }
        if battery.temperature > 42 || (battery.percent < 10 && !battery.externalPower) { return .hot }
        if battery.temperature > 38 || (battery.percent < 20 && !battery.externalPower) { return .warm }
        return .calm
    }
    func powerHealth(chipClass: String) -> Health {
        let hot: Double = ["Ultra": 120, "Max": 80, "Pro": 45][chipClass] ?? 22
        return Health.grade(sysPower, warm: hot * 0.45, hot: hot)
    }
    func overall(chipClass: String) -> Health {
        [cpuTempMaxHealth, gpuTempHealth, ssdTempHealth, memoryHealth, powerHealth(chipClass: chipClass), batteryHealth].max() ?? .calm
    }
}

/// Orchestrates all sources. Call `sample()` from a background queue every few seconds.
final class Sampler {
    let soc: SocInfo
    private let ioreport: IOReport?
    private let smc: SMC?
    private let hid: IOHIDSensors?
    private let procs = ProcessSampler()
    // Every temperature key the SMC exposes, and the subset that is actually reporting a live die.
    // A full sweep of ~190 keys costs ~28 ms; the live subset is a fraction of that. Parked clusters
    // report an exact 40.0 °C placeholder or a sub-ambient value, and can wake later, so the full
    // set is re-classified periodically.
    private var smcCPUKeys: [String] = [], smcGPUKeys: [String] = [], smcFanKeys: [String] = []
    private var liveCPUKeys: [String] = [], liveGPUKeys: [String] = []
    private var lastKeyScan: TimeInterval = -1e9
    /// IOHID services worth reading every sample: SSD and battery, plus die sensors when the SMC
    /// has none (M1 / older macOS).
    private var hotHIDNames: Set<String> = []
    private var prevDisk: (DiskStats, TimeInterval)?
    private var prevNet: (NetworkStats, TimeInterval)?
    private var lastProcSample: TimeInterval = 0
    /// Guards the SMC connection and the IOHID client. `sample()` spends most of its wall time
    /// asleep inside IOReport's interval wait, so an on-demand sensor read from another queue only
    /// has to wait for the short thermal section rather than for the whole sampling interval.
    private let sensorLock = NSLock()
    private var cachedProcs: [ProcessStat] = []

    init?() {
        guard let soc = SocInfo.load() else { return nil }
        self.soc = soc
        ioreport = IOReport()
        smc = SMC()
        hid = IOHIDSensors()
        if let smc {
            for k in smc.allKeys() where k.count == 4 {
                if k.hasPrefix("F"), k.hasSuffix("Ac") { smcFanKeys.append(k); continue }
                let isCPU = k.hasPrefix("Tp") || k.hasPrefix("Te") || k.hasPrefix("Ts")
                let isGPU = k.hasPrefix("Tg")
                guard isCPU || isGPU, let v = smc.read(k), v.type == "flt ", let f = SMC.numeric(v), f > 0, f < 150 else { continue }
                if isCPU { smcCPUKeys.append(k) } else { smcGPUKeys.append(k) }
            }
            smcFanKeys = Array(Set(smcFanKeys)).sorted()
        }
        classifyLiveKeys(now: 0)

        if let hid {
            let needsDieFromHID = smcCPUKeys.isEmpty || smcGPUKeys.isEmpty
            for name in hid.sensorNames {
                let upper = name.uppercased(), lower = name.lowercased()
                if upper.contains("NAND") || lower.contains("battery") || lower.contains("gas gauge") {
                    hotHIDNames.insert(name)
                } else if needsDieFromHID,
                          name.hasPrefix("pACC MTR") || name.hasPrefix("eACC MTR") || name.hasPrefix("GPU MTR") {
                    hotHIDNames.insert(name)
                }
            }
        }
    }

    /// Re-test every SMC temperature key and keep the ones reporting a plausible live die value.
    private func classifyLiveKeys(now: TimeInterval) {
        guard let smc else { return }
        lastKeyScan = now
        liveCPUKeys = smcCPUKeys.filter { key in
            guard let v = smc.readFloat(key) else { return false }
            return v >= 20 && v != 40.0 && v < 150
        }
        liveGPUKeys = smcGPUKeys.filter { key in
            guard let v = smc.readFloat(key) else { return false }
            return v >= 20 && v < 150
        }
        // If everything looked parked, fall back to the full set rather than reporting nothing.
        if liveCPUKeys.isEmpty { liveCPUKeys = smcCPUKeys }
        if liveGPUKeys.isEmpty { liveGPUKeys = smcGPUKeys }
    }

    var sourcesDescription: String {
        let smcPart = smc != nil
            ? "on(cpu \(liveCPUKeys.count)/\(smcCPUKeys.count), gpu \(liveGPUKeys.count)/\(smcGPUKeys.count), fan \(smcFanKeys.count))"
            : "off"
        return "IOReport:\(ioreport != nil ? "on" : "off") SMC:\(smcPart) IOHID:\(hid != nil ? "on(\(hotHIDNames.count) hot)" : "off")"
    }

    private func calcFreq(_ items: [(String, Int64)], freqs: [UInt32]) -> (Int, Double, Double) {
        guard !freqs.isEmpty, items.count > freqs.count,
              let offset = items.firstIndex(where: { !["IDLE", "DOWN", "OFF"].contains($0.0) }) else { return (0, 0, 0) }
        let usage = items.dropFirst(offset).prefix(freqs.count).reduce(0.0) { $0 + Double($1.1) }
        let total = items.reduce(0.0) { $0 + Double($1.1) }
        var avg = 0.0
        for i in 0..<freqs.count where i + offset < items.count {
            avg += zeroDiv(Double(items[i + offset].1), usage) * Double(freqs[i])
        }
        let active = zeroDiv(usage, total)
        let minF = Double(freqs.first!), maxF = Double(freqs.last!)
        let scaled = zeroDiv(max(avg, minF) * active, maxF)
        return (Int(avg), scaled, active)
    }

    /// - Parameter allSensors: sweep every SMC key and IOHID service, for the "all sensors" panel.
    ///   That full sweep costs roughly 60 ms more than the live subset the rest of the app needs,
    ///   so it only runs while the panel is actually on screen.
    func sample(interval: Double, allSensors: Bool = false) -> Snapshot {
        var s = Snapshot()
        s.interval = interval
        s.uptime = ProcessInfo.processInfo.systemUptime
        var la = [Double](repeating: 0, count: 3); getloadavg(&la, 3); s.loadAvg = (la[0], la[1], la[2])

        if let ioreport, let sample = ioreport.sampleSincePrevious() {
            var cores: [CoreMetric] = []
            for ch in sample.channels {
                switch (ch.group, ch.subgroup) {
                case ("CPU Stats", "CPU Core Performance States"):
                    let isP = ch.name.contains("PCPU")
                    guard isP || ch.name.contains("ECPU") || ch.name.contains("MCPU") else { continue }
                    let (f, sc, ac) = calcFreq(ioreport.residencies(ch.item), freqs: isP ? soc.pcpuFreqs : soc.ecpuFreqs)
                    let key = Self.coreSortKey(ch.name)
                    cores.append(CoreMetric(id: ch.name, isP: isP, die: key.0, index: key.3, freqMHz: f, scaled: sc, active: ac))
                case ("GPU Stats", "GPU Performance States") where ch.name == "GPUPH":
                    let (f, sc, ac) = calcFreq(ioreport.residencies(ch.item), freqs: Array(soc.gpuFreqs.dropFirst()))
                    s.gpuFreq = f; s.gpuUsage = sc; s.gpuActive = ac
                case ("Energy Model", _):
                    let w = ioreport.watts(ch, elapsed: sample.elapsed)
                    if ch.name == "GPU Energy" { s.gpuPower += w }
                    else if ch.name.hasSuffix("CPU Energy") { s.cpuPower += w }
                    else if ch.name.hasPrefix("ANE") { s.anePower += w }
                    else if ch.name.hasPrefix("DRAM") { s.ramPower += w }
                default: break
                }
            }
            cores.sort { Self.coreSortKey($0.id) < Self.coreSortKey($1.id) }
            s.cores = cores
            let e = cores.filter { !$0.isP }, p = cores.filter { $0.isP }
            let eCount = Double(max(e.count, soc.ecpuCores)), pCount = Double(max(p.count, soc.pcpuCores))
            s.ecpuUsage = zeroDiv(e.reduce(0) { $0 + $1.scaled }, eCount)
            s.pcpuUsage = zeroDiv(p.reduce(0) { $0 + $1.scaled }, pCount)
            s.cpuUsage = zeroDiv(cores.reduce(0) { $0 + $1.scaled }, eCount + pCount)
            s.cpuActive = zeroDiv(cores.reduce(0) { $0 + $1.active }, eCount + pCount)
            s.ecpuFreq = max(Int(zeroDiv(e.reduce(0) { $0 + Double($1.freqMHz) }, Double(e.count))), Int(soc.ecpuFreqs.first ?? 0))
            s.pcpuFreq = max(Int(zeroDiv(p.reduce(0) { $0 + Double($1.freqMHz) }, Double(p.count))), Int(soc.pcpuFreqs.first ?? 0))
        }

        // Thermals: SMC (macOS 14+) preferred for CPU/GPU, IOHID for everything incl. NAND/battery.
        // A power-gated GPU or CPU cluster leaves its die sensors reporting near-zero garbage
        // (observed: Tg keys at 1.6 °C while the CPU sat at 47 °C), so die averages take a floor:
        // no silicon in a running Mac is below room temperature.
        let dieFloor = 20.0
        sensorLock.lock()
        var sensors: [Sensor] = []
        var cpuT: [Double] = [], gpuT: [Double] = [], ssdT: [Double] = []
        if allSensors { sensors.reserveCapacity(smcCPUKeys.count + smcGPUKeys.count + 32) }
        // A cluster that was parked at startup can wake up later, so re-classify now and then.
        if s.uptime - lastKeyScan > 60 { classifyLiveKeys(now: s.uptime) }
        let cpuKeys = allSensors ? smcCPUKeys : liveCPUKeys
        let gpuKeys = allSensors ? smcGPUKeys : liveGPUKeys
        if let smc {
                for k in cpuKeys {
                guard let v = smc.readFloat(k), v > 0, v < 150 else { continue }
                if allSensors { sensors.append(Sensor(id: "smc.\(k)", name: k, value: Double(v), source: "SMC")) }
                // Apple pads the Tp* table with an exact 40.0 °C placeholder on unused sensors.
                if Double(v) >= dieFloor, v != 40.0 { cpuT.append(Double(v)) }
            }
            for k in gpuKeys {
                guard let v = smc.readFloat(k), v > 0, v < 150 else { continue }
                if allSensors { sensors.append(Sensor(id: "smc.\(k)", name: k, value: Double(v), source: "SMC")) }
                if Double(v) >= dieFloor { gpuT.append(Double(v)) }
            }
            if let p = smc.readFloat("PSTR"), p > 0 { s.sysPower = Double(p) }
            for (i, k) in smcFanKeys.enumerated() {
                guard let v = smc.read(k), let rpm = SMC.numeric(v), rpm >= 0, rpm < 100_000 else { continue }
                var mx: Int? = nil
                if let mv = smc.read(String(k.dropLast(2)) + "Mx"), let m = SMC.numeric(mv), m > 0 { mx = Int(m) }
                s.fans.append(FanMetric(id: "Fan \(i + 1)", rpm: Int(rpm), maxRPM: mx))
            }
        }
        if let hid {
            var hidCPU: [Double] = [], hidGPU: [Double] = []
            for (name, t) in hid.temperatures(only: allSensors ? nil : hotHIDNames) {
                if allSensors { sensors.append(Sensor(id: "hid.\(name).\(sensors.count)", name: name, value: t, source: "HID")) }
                if name.hasPrefix("pACC MTR") || name.hasPrefix("eACC MTR") { if t >= dieFloor { hidCPU.append(t) } }
                else if name.hasPrefix("GPU MTR") { if t >= dieFloor { hidGPU.append(t) } }
                else if name.uppercased().contains("NAND") { ssdT.append(t) }
                else if name.lowercased().contains("battery") || name.lowercased().contains("gas gauge") { s.batteryTemp = max(s.batteryTemp, t) }
            }
            if cpuT.isEmpty { cpuT = hidCPU }
            if gpuT.isEmpty { gpuT = hidGPU }
        }
        // SMC exposes dozens of Tp*/Te*/Tg* keys, many of them on parked clusters reading far below the
        // active die. Average only sensors within 15 °C of the hottest one, and report that max separately.
        sensorLock.unlock()

        s.cpuTempMax = cpuT.max() ?? 0
        s.cpuTemp = Self.dieAverage(cpuT)
        s.gpuTemp = Self.dieAverage(gpuT)
        s.ssdTemp = ssdT.max() ?? 0
        s.sensors = sensors.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        s.sysPower = max(s.sysPower, s.allPower)

        s.memory = MemoryStats.read()
        s.battery = BatteryStats.read()
        if s.batteryTemp == 0 { s.batteryTemp = s.battery.temperature }

        let disk = DiskStats.read()
        if let (pd, pt) = prevDisk, s.uptime > pt {
            let dt = s.uptime - pt
            s.diskReadPerSec = Double(disk.readBytes &- pd.readBytes) / dt
            s.diskWritePerSec = Double(disk.writeBytes &- pd.writeBytes) / dt
        }
        prevDisk = (disk, s.uptime); s.disk = disk

        let net = NetworkStats.read()
        if let (pn, pt) = prevNet, s.uptime > pt {
            let dt = s.uptime - pt
            s.netInPerSec = net.inBytes >= pn.inBytes ? Double(net.inBytes - pn.inBytes) / dt : 0
            s.netOutPerSec = net.outBytes >= pn.outBytes ? Double(net.outBytes - pn.outBytes) / dt : 0
        }
        prevNet = (net, s.uptime)
        s.network = net

        // Measured at 1.3 ms for the whole table, so it runs on every sample regardless of whether
        // the dashboard is open — otherwise the process list would be blank for the first cycle or
        // two after opening it, and CPU percentages need a previous baseline anyway.
        if s.uptime - lastProcSample >= 1 {
            cachedProcs = procs.sample().sorted { $0.cpuPercent > $1.cpuPercent }
            lastProcSample = s.uptime
        }
        s.processes = Array(cachedProcs.prefix(8))
        return s
    }

    /// Every temperature the machine exposes. Costs a full SMC and IOHID sweep (~70 ms), so it is
    /// only called for the "all sensors" panel — once when it opens, then with each sample while it
    /// stays open. Safe to call from any queue; access to the hardware is serialised internally.
    func readAllSensors() -> [Sensor] {
        sensorLock.lock()
        defer { sensorLock.unlock() }
        var sensors: [Sensor] = []
        if let smc {
            for k in smcCPUKeys + smcGPUKeys {
                guard let v = smc.readFloat(k), v > 0, v < 150 else { continue }
                sensors.append(Sensor(id: "smc.\(k)", name: k, value: Double(v), source: "SMC"))
            }
        }
        if let hid {
            for (name, t) in hid.temperatures() {
                sensors.append(Sensor(id: "hid.\(name).\(sensors.count)", name: name, value: t, source: "HID"))
            }
        }
        return sensors.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// Mean of the sensors that are actually reporting the live die: everything within 15 °C of the peak.
    private static func dieAverage(_ temps: [Double]) -> Double {
        guard let peak = temps.max() else { return 0 }
        let live = temps.filter { $0 >= peak - 15 }
        return zeroDiv(live.reduce(0, +), Double(live.count))
    }

    private static func coreSortKey(_ ch: String) -> (Int, Int, Int, Int) {
        var die = 0
        if ch.hasPrefix("DIE_"), let d = Int(ch.dropFirst(4).prefix { $0.isNumber }) { die = d }
        let tier = ch.contains("ECPU") ? 0 : ch.contains("MCPU") ? 1 : 2
        let prefix = ["ECPU", "MCPU", "PCPU"].first { ch.contains($0) } ?? ""
        let rest = ch[(ch.range(of: prefix)?.upperBound ?? ch.endIndex)...]
        if let r = rest.range(of: "_CPU") {
            let cluster = Int(rest[..<r.lowerBound]) ?? 0
            let core = Int(rest[r.upperBound...].prefix { $0.isNumber }) ?? 0
            return (die, tier, cluster, core)
        }
        return (die, tier, 0, Int(rest.prefix { $0.isNumber }) ?? 0)
    }
}
