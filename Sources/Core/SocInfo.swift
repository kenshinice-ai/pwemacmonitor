import Foundation
import IOKit

/// Static SoC description + DVFS frequency tables (port of macmon's SocInfo).
struct SocInfo {
    var chipName = "", macModel = "", memoryGB = 0
    var ecpuCores = 0, pcpuCores = 0, gpuCores = 0
    var ecpuLabel = "E", pcpuLabel = "P"
    var ecpuFreqs: [UInt32] = [], pcpuFreqs: [UInt32] = [], gpuFreqs: [UInt32] = []

    var isLegacyNaming: Bool { ["M1", "M2", "M3", "M4", "A1"].contains { chipName.contains($0) } }
    var chipClass: String {
        for c in ["Ultra", "Max", "Pro"] where chipName.contains(c) { return c }
        return "Base"
    }

    static func load() -> SocInfo? {
        var info = SocInfo()
        info.chipName = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        info.macModel = sysctlString("hw.model") ?? ""
        info.memoryGB = Int((sysctlValue("hw.memsize", UInt64.self) ?? 0) / (1 << 30))

        let levels = sysctlValue("hw.nperflevels", UInt32.self) ?? 1
        if levels >= 2 {
            info.pcpuCores = Int(sysctlValue("hw.perflevel0.physicalcpu", UInt32.self) ?? 0)
            info.ecpuCores = Int(sysctlValue("hw.perflevel\(levels - 1).physicalcpu", UInt32.self) ?? 0)
        } else {
            info.pcpuCores = Int(sysctlValue("hw.physicalcpu", UInt32.self) ?? 0)
        }
        if !info.isLegacyNaming { info.ecpuLabel = "P"; info.pcpuLabel = "S" }

        if let gpu = ioFirstProperties("AGXAccelerator"), let n = gpu["gpu-core-count"] as? Int { info.gpuCores = n }

        // pmgr stores DVFS tables in Hz (M1–M3), kHz (M4+) or MHz depending on chip/OS — detect by magnitude.
        guard let pmgr = ioFirstProperties("AppleARMIODevice", named: "pmgr") else { return nil }
        info.ecpuFreqs = cpuFreqs(pmgr, key: "voltage-states1-sram", isE: true) ?? []
        info.pcpuFreqs = cpuFreqs(pmgr, key: "voltage-states5-sram", isE: false) ?? []
        info.gpuFreqs = dvfsMHz(pmgr, key: "voltage-states9") ?? []
        guard !info.ecpuFreqs.isEmpty, !info.pcpuFreqs.isEmpty else { return nil }
        return info
    }

    private static func dvfsMHz(_ dict: [String: Any], key: String) -> [UInt32]? {
        guard let data = dict[key] as? Data, data.count >= 8 else { return nil }
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
}
