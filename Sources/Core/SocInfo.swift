import Foundation
import IOKit

/// One tier of CPU cores: the efficiency cores, the performance cores, the super cores.
struct CPUTier {
    /// One letter, from the system's own name for the level: "E", "P", "S".
    var label: String
    var cores: Int
    /// The tier's DVFS table in MHz, slowest state first. Empty when the chip did not publish one.
    var freqs: [UInt32]
}

/// Static SoC description + DVFS frequency tables (port of macmon's SocInfo).
///
/// **Tiers, not "E and P" (1.8.0).** M1 to M5 have two kinds of core. M6 has three — two Super,
/// four Performance, six Efficiency — and `hw.nperflevels` says 3. Until 1.8.0 this read level 0 and
/// the last level and nothing between, so an M6 would have shown "E6 + S2" and run its four
/// Performance cores through the Efficiency cores' frequency table. `tiers` holds every level the
/// system reports, slowest first, the order macmon's `cpu_tiers` uses.
struct SocInfo {
    var chipName = "", macModel = "", memoryGB = 0
    var gpuCores = 0
    /// Slowest first. One tier on a machine that reports no levels (a virtual machine).
    var tiers: [CPUTier] = []
    var gpuFreqs: [UInt32] = []

    // The slowest and the fastest tier, under the names everything before 1.8.0 used. On a
    // single-level machine there is no slow tier, and the fast one is all of it.
    var ecpuCores: Int { tiers.count > 1 ? tiers[0].cores : 0 }
    var pcpuCores: Int { tiers.last?.cores ?? 0 }
    var ecpuLabel: String { tiers.count > 1 ? tiers[0].label : "E" }
    var pcpuLabel: String { tiers.last?.label ?? "P" }
    var ecpuFreqs: [UInt32] { tiers.count > 1 ? tiers[0].freqs : [] }
    var pcpuFreqs: [UInt32] { tiers.last?.freqs ?? [] }
    var cpuCores: Int { tiers.reduce(0) { $0 + $1.cores } }
    /// "E6 + P4 + S2", slowest first, as the silicon card's title has always ordered it.
    var tierSummary: String { tiers.map { "\($0.label)\($0.cores)" }.joined(separator: " + ") }

    var isLegacyNaming: Bool { Self.isLegacy(chipName) }
    var chipClass: String {
        for c in ["Ultra", "Max", "Pro"] where chipName.contains(c) { return c }
        return "Base"
    }

    static func load() -> SocInfo? {
        var info = SocInfo()
        info.chipName = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        info.macModel = sysctlString("hw.model") ?? ""
        info.memoryGB = Int((sysctlValue("hw.memsize", UInt64.self) ?? 0) / (1 << 30))

        // Level 0 is the fastest; reversed below, so the tiers run slowest first.
        let levels = Int(sysctlValue("hw.nperflevels", UInt32.self) ?? 1)
        var counts: [Int] = [], names: [String?] = []
        if levels >= 2 {
            for i in (0..<levels).reversed() {
                counts.append(Int(sysctlValue("hw.perflevel\(i).physicalcpu", UInt32.self) ?? 0))
                names.append(sysctlString("hw.perflevel\(i).name"))
            }
        } else {
            counts = [Int(sysctlValue("hw.physicalcpu", UInt32.self) ?? 0)]
            names = [nil]
        }
        let labels = tierLabels(names: names, legacy: isLegacy(info.chipName))

        if let gpu = ioFirstProperties("AGXAccelerator"), let n = gpu["gpu-core-count"] as? Int { info.gpuCores = n }

        // M6 moved the DVFS tables from `pmgr` to a new `pmgr-child` and left `pmgr` a stub
        // (macmon #79: Mac18,5 on macOS 27.0 failed with "No CPU frequencies found"). Read both.
        // Until 1.8.0 a missing table returned nil here and the app said it needed an Apple
        // Silicon Mac — to the owner of the newest one. A missing table now costs the frequency
        // readings only; usage falls back to residency (`Sampler.calcFreq`).
        let pmgr = mergedProperties(ioAllProperties("AppleARMIODevice", named: ["pmgr", "pmgr-child"]))
        let slow = cpuFreqs(pmgr, key: "voltage-states1-sram", isE: true) ?? []
        let fast = cpuFreqs(pmgr, key: "voltage-states5-sram", isE: false) ?? []
        info.tiers = zip(labels, counts).enumerated().map { i, t in
            CPUTier(label: t.0, cores: t.1, freqs: freqTableIndex(tier: i, of: counts.count) == 0 ? slow : fast)
        }
        info.gpuFreqs = dvfsMHz(pmgr, key: "voltage-states9") ?? []
        return info
    }

    static func isLegacy(_ chipName: String) -> Bool { ["M1", "M2", "M3", "M4", "A1"].contains { chipName.contains($0) } }

    /// One letter per tier, slowest first. The system's own names win ("Efficiency",
    /// "Performance", "Super"); a level it does not name keeps a default by position. Two levels
    /// were E and P up to M4, and P and S from M5, where the slower kind is called Performance.
    static func tierLabels(names: [String?], legacy: Bool) -> [String] {
        let defaults: [String]
        switch names.count {
        case 1: defaults = ["P"]
        case 2: defaults = legacy ? ["E", "P"] : ["P", "S"]
        case 3: defaults = ["E", "P", "S"]
        default: defaults = (0..<names.count).map { "C\($0)" }
        }
        return zip(names, defaults).map { name, fallback in
            guard let c = name?.first, c.isLetter else { return fallback }
            return String(c).uppercased()
        }
    }

    /// Which of the two published CPU tables a tier uses: 0 for the efficiency table, 1 for the
    /// performance table. The slowest tier of a multi-level chip takes the first, every other
    /// tier the second. M6's Performance cores share the Super cores' 20-state table
    /// (`PACC0_PCPU` and `PACC0_MCPU`, macmon #79) — macmon's inference, not yet verified, and
    /// this follows it.
    static func freqTableIndex(tier: Int, of count: Int) -> Int { count > 1 && tier == 0 ? 0 : 1 }

    /// Several nodes' properties as one dictionary; the first node to have a key keeps it, so a
    /// stub `pmgr` cannot blank out what `pmgr-child` holds.
    static func mergedProperties(_ nodes: [[String: Any]]) -> [String: Any] {
        var out: [String: Any] = [:]
        for node in nodes { for (k, v) in node where out[k] == nil { out[k] = v } }
        return out
    }

    private static func dvfsMHz(_ dict: [String: Any], key: String) -> [UInt32]? {
        guard let data = dict[key] as? Data else { return nil }
        return dvfsMHz(data)
    }

    /// pmgr stores DVFS tables in Hz (M1–M3), kHz (M4+) or MHz depending on chip/OS — detected by
    /// magnitude. Pairs of little-endian (frequency, voltage).
    static func dvfsMHz(_ data: Data) -> [UInt32]? {
        guard data.count >= 8 else { return nil }
        let raw = stride(from: 0, to: data.count - 7, by: 8).map { i in
            data.subdata(in: i..<i + 4).withUnsafeBytes { $0.load(as: UInt32.self) }
        }
        let peak = raw.max() ?? 0
        let scale: UInt32 = peak > 50_000_000 ? 1_000_000 : peak > 50_000 ? 1_000 : 1
        return raw.map { $0 / scale }
    }

    private static func cpuFreqs(_ dict: [String: Any], key: String, isE: Bool) -> [UInt32]? {
        if let f = dvfsMHz(dict, key: key) { return f }
        // M5+: discover cluster keys from acc-clusters (8-byte entries: [voltage-state index, tier, ...])
        guard let acc = dict["acc-clusters"] as? Data, acc.count >= 16 else { return nil }
        var clusters: [(UInt8, String)] = []
        for i in stride(from: 0, to: acc.count - 7, by: 8) { clusters.append((acc[i + 1], "voltage-states\(acc[i])-sram")) }
        clusters.sort { $0.0 < $1.0 }
        guard clusters.count >= 2 else { return nil }
        let k = isE ? clusters[clusters.count - 2].1 : clusters[clusters.count - 1].1
        return dvfsMHz(dict, key: k)
    }

    /// What `pwemon --channels` prints about the chip: enough to fit a new one without having it.
    static func diagnostics() -> [String] {
        var out: [String] = []
        let levels = Int(sysctlValue("hw.nperflevels", UInt32.self) ?? 0)
        let lv = (0..<levels).map { i in
            "\(i): \(sysctlString("hw.perflevel\(i).name") ?? "?") ×\(sysctlValue("hw.perflevel\(i).physicalcpu", UInt32.self) ?? 0)"
        }
        out.append("Perf levels   \(levels) — \(lv.joined(separator: ", "))")
        let nodes = ioAllProperties("AppleARMIODevice", named: ["pmgr", "pmgr-child"], withNames: true)
        if nodes.isEmpty { out.append("pmgr          none found") }
        for (name, props) in nodes {
            let tables = props.keys.filter { $0.hasPrefix("voltage-states") }.sorted { a, b in
                a.compare(b, options: .numeric) == .orderedAscending
            }.map { k -> String in
                let f = (props[k] as? Data).flatMap(dvfsMHz) ?? []
                return f.isEmpty ? k : "\(k) ×\(f.count) (\(f.min() ?? 0)–\(f.max() ?? 0) MHz)"
            }
            out.append("\(name.padding(toLength: 13, withPad: " ", startingAt: 0)) \(tables.isEmpty ? "no voltage-states tables" : tables.joined(separator: ", "))")
            if let acc = props["acc-clusters"] as? Data {
                out.append("  acc-clusters \(acc.map { String(format: "%02x", $0) }.joined())")
            }
        }
        return out
    }
}

/// Every matching service's properties, in registry order, optionally only those with one of the
/// given names. `withNames` keeps each node's name beside its properties, for diagnostics.
func ioAllProperties(_ serviceName: String, named: Set<String>) -> [[String: Any]] {
    ioAllProperties(serviceName, named: named, withNames: true).map(\.1)
}

func ioAllProperties(_ serviceName: String, named: Set<String>, withNames: Bool) -> [(String, [String: Any])] {
    guard let it = IOServiceIterator(serviceName) else { return [] }
    var out: [(String, [String: Any])] = []
    while let (entry, name) = it.next() {
        defer { IOObjectRelease(entry) }
        guard named.contains(name), let props = ioProperties(entry) else { continue }
        out.append((name, props))
    }
    return out
}
