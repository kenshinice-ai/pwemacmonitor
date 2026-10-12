import Foundation
import IOKit

/// The AppleCLPC aggregate energy counters — the one place macOS 27 still reports the Neural
/// Engine's power every second to a process that is not root.
///
/// macOS 27 batches the Energy Model's counters: ANE and DRAM arrive every several minutes, so
/// 1.5.0 to 1.6.0 left both rails out. The CLPC driver keeps its own counters, in nanojoules,
/// updated continuously. They are not in the list `IOReportCopyAllChannels` returns; a
/// subscription has to name them by a 64-bit report ID, and the IDs are not published.
///
/// **The table is macmon's** (github.com/vladkens/macmon, `src/clpc.rs` at commit `afdd572`, MIT —
/// see THIRD-PARTY-NOTICES.md). Its author extracted the IDs from Apple's kernelcaches for macOS
/// 27.0 (26A428) and 27.0.1 (26A434). An ID is `(table index << 32) | key`: the key belongs to
/// the driver, the index to the OS release — between macOS 26 and 27 the ANE index moved from 23
/// to 24. So this table is good for one major version, and nothing in it says when it stops
/// being true. `Sampler` therefore never trusts it on its own word; see `Sampler.clpcAgrees`.
///
/// **Only the ANE figure is shown.** Measured against `powermetrics` on an M4 Max, 2026-10-12
/// (docs/power-rails.md): CLPC's ANE counter was within 0.1 % at 3.58 W, twice. Its CPU counter
/// read 5.7 % high at full load and its GPU counter carried an intermittent half watt, so the CPU
/// stays on the cluster histograms and the GPU on the Energy Model. The CPU counter is still
/// subscribed — as the witness that the table is the right one for the OS it is running on.
///
/// **1.7.1: a Mac with no cluster histograms.** An M3 and an M5 Max list none, so 1.7.0 showed
/// no CPU power on either and its witness never spoke. There the CPU figure is CLPC's, and the
/// witness is the GPU pair instead: CLPC's GPU counter against the Energy Model's `GPU Energy`,
/// the one Energy Model counter macOS 27 still updates every second on every chip.
enum CLPC {
    /// Table indices for macOS 27.
    static let cpuIndex: UInt64 = 16, gpuIndex: UInt64 = 25, aneIndex: UInt64 = 24

    /// Driver bundle → (CPU key, GPU key, ANE key).
    static let keys: [String: (cpu: UInt32, gpu: UInt32, ane: UInt32)] = [
        "com.apple.driver.AppleT6000CLPCv3": (0x4747_9059, 0x4519_bf1e, 0x9aaa_17f8),
        "com.apple.driver.AppleT6002CLPC": (0xb501_816b, 0x9e2c_3e8b, 0x14d5_a574),
        "com.apple.driver.AppleT6020CLPC": (0xe301_cd75, 0x8f34_cc7a, 0x7415_fb0f),
        "com.apple.driver.AppleT6022CLPC": (0x76f5_fd21, 0x9062_4499, 0x3c09_7307),
        "com.apple.driver.AppleT6030CLPC": (0xbe03_a01a, 0x472d_6c9c, 0xb899_0c38),
        "com.apple.driver.AppleT6031CLPC": (0xd81e_0084, 0x1085_f98b, 0x313a_3be1),
        "com.apple.driver.AppleT6032CLPC": (0xf4a2_1308, 0x85e8_0513, 0x63dc_8e25),
        "com.apple.driver.AppleT6041CLPC": (0x263c_f1f0, 0x22e4_cf59, 0x7849_fb5c),
        "com.apple.driver.AppleT6050CLPC": (0xd3ab_60bb, 0x27cd_4ce5, 0x8c0f_1c59),
        "com.apple.driver.AppleT6050dCLPC": (0x18b3_010e, 0xedec_a11a, 0x188b_d883),
        "com.apple.driver.AppleT8103CLPCv3": (0x2cdd_31f2, 0x21be_cf42, 0x0667_fb81),
        "com.apple.driver.AppleT8112CLPC": (0xb543_5137, 0x638d_9d52, 0xea08_9c36),
        "com.apple.driver.AppleT8122CLPC": (0x54b5_1c99, 0xce2d_d9dc, 0x960a_fe2f),
        "com.apple.driver.AppleT8132CLPC": (0x4a85_4d94, 0x3b3e_3b79, 0x1ff4_a9ec),
        "com.apple.driver.AppleT8140CLPC": (0x9bf5_4436, 0xef70_589c, 0x569d_941b),
        "com.apple.driver.AppleT8142CLPC": (0x4370_8744, 0x6a01_0933, 0xbc5e_fdf0),
        "com.apple.driver.AppleT8152CLPC": (0x485d_4bfc, 0x1178_4654, 0x9380_c6bb),
    ]

    static let group = "CLPC", cpuName = "CPU Energy", gpuName = "GPU Energy", aneName = "ANE"

    /// Report IDs for a driver on an OS, or nil when the table does not cover the pair. Unknown
    /// drivers and every major version but 27 get nothing: a guessed ID reads some other counter.
    static func reportIDs(bundle: String, osMajor: Int) -> (cpu: UInt64, gpu: UInt64, ane: UInt64)? {
        guard osMajor == 27, let k = keys[bundle] else { return nil }
        return ((cpuIndex << 32) | UInt64(k.cpu), (gpuIndex << 32) | UInt64(k.gpu), (aneIndex << 32) | UInt64(k.ane))
    }

    /// Names the table a witness has checked: this build of macOS on this driver. A new build
    /// is a new key, so an update starts from "not yet witnessed" without anyone clearing anything.
    static let tableKey: String? = {
        guard let d = driver(),
              reportIDs(bundle: d.bundle, osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) != nil
        else { return nil }
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf) + "|" + d.bundle
    }()
    /// The preference that holds the last `tableKey` a witness agreed with.
    static let witnessedDefault = "clpcWitnessed"

    /// This Mac's CLPC driver: its bundle identifier and registry entry ID.
    static func driver() -> (bundle: String, id: UInt64)? {
        guard let it = IOServiceIterator("AppleCLPC") else { return nil }
        while let (entry, _) = it.next() {
            defer { IOObjectRelease(entry) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS,
                  let bundle = IORegistryEntryCreateCFProperty(entry, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { continue }
            return (bundle, id)
        }
        return nil
    }

    /// The three channel descriptors to append to an IOReport subscription, or none.
    ///
    /// Mutable on purpose: IOReport's getters cache what they derive in the dictionary they are
    /// handed. The type and unit words are IOReportTypes.h's — a simple integer in the power
    /// category with one element, counted in nanojoules.
    static func channels(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> [NSMutableDictionary] {
        guard let d = driver(), let ids = reportIDs(bundle: d.bundle, osMajor: osMajor) else { return [] }
        let type: Int64 = 1 | (2 << 16) | (1 << 32), unit: Int64 = (3 << 56) | (118 << 32)
        return [(ids.cpu, cpuName), (ids.gpu, gpuName), (ids.ane, aneName)].map { id, name in
            NSMutableDictionary(dictionary: [
                "DriverID": NSNumber(value: Int64(bitPattern: d.id)), "DriverName": "AppleCLPC",
                "IOReportGroupName": group, "IOReportSubGroupName": "Energy Counters",
                "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: unit)],
                "LegendChannel": [NSNumber(value: Int64(bitPattern: id)), NSNumber(value: type), name],
            ])
        }
    }
}
