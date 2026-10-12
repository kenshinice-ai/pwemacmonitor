// Rail probe: every power source this Mac offers, side by side, once a second, through a fixed
// sequence of loads — plus the memory readings plan 32 depends on. Run by Tools/compare-rails.sh,
// which runs Apple's powermetrics (as root) beside it; this process never runs as root.
//
//   swiftc -O -swift-version 5 Sources/Core/*.swift Tools/railprobe/main.swift \
//     -framework IOKit -framework Metal -framework Vision -o /tmp/railprobe
//   /tmp/railprobe out.tsv            # RAILPROBE_SCALE=0.2 shortens every phase, for a dry run
//
// The CLPC report IDs are from macmon (src/clpc.rs @ afdd572, MIT): macOS 27.0 / 27.0.1 only.
import Foundation
import IOKit
import Metal
import Vision
import CoreGraphics

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: schedule

let scale = Double(ProcessInfo.processInfo.environment["RAILPROBE_SCALE"] ?? "1") ?? 1
/// `power` as the second argument leaves the memory phases out and gives the CPU longer at full load.
let powerOnly = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "power"
let plan: [(String, Double)] = powerOnly
    ? [("quiet", 12), ("cpu", 35), ("quiet", 10), ("gpu", 20), ("quiet", 8), ("ane", 15), ("quiet", 5)]
    : [("quiet", 15), ("cpu", 20), ("quiet", 10), ("gpu", 20), ("quiet", 10),
       ("ane", 20), ("quiet", 10), ("mem-warn", 16), ("mem-critical", 12), ("quiet", 14)]
var edges: [(String, Double)] = []          // (phase, end time)
var acc = 0.0
for (name, seconds) in plan { acc += seconds * scale; edges.append((name, acc)) }
let total = acc
let started = ProcessInfo.processInfo.systemUptime
func phase() -> String {
    let t = ProcessInfo.processInfo.systemUptime - started
    return edges.first { t < $0.1 }?.0 ?? "done"
}

// MARK: loads — each thread asks what phase it is; nothing is hoisted out of a function call

/// Somewhere for the arithmetic to land. Without a reader the optimiser deletes the loop, and the
/// first run of this probe "pinned every core" at 6.8 W.
final class Sink: @unchecked Sendable { private let l = NSLock(); private var v = 0.0
    func take(_ x: Double) { l.lock(); v += x; l.unlock() } }
let sink = Sink()
for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
    let t = Thread {
        var a = 1.0
        while true {
            if phase() == "cpu" { for _ in 0..<2_000_000 { a = a * 1.0000001 + 1e-9; if a > 1e12 { a = 1.0 } }; sink.take(a) }
            else if phase() == "done" { return } else { usleep(50_000) }
        }
    }
    t.qualityOfService = .userInitiated; t.start()
}
let gpu = Thread {
    guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
    let src = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void burn(device float* out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
        float a = out[i];
        for (int k = 0; k < 8192; k++) { a = fma(a, 1.0000001f, 1e-9f); }
        out[i] = a;
    }
    """
    guard let lib = try? dev.makeLibrary(source: src, options: nil), let fn = lib.makeFunction(name: "burn"),
          let pipe = try? dev.makeComputePipelineState(function: fn),
          let buf = dev.makeBuffer(length: 1 << 22, options: .storageModePrivate) else { return }
    let n = (1 << 22) / MemoryLayout<Float>.size
    while true {
        let p = phase()
        if p == "done" { return }
        if p != "gpu" { usleep(50_000); continue }
        guard let cb = q.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { return }
        e.setComputePipelineState(pipe); e.setBuffer(buf, offset: 0, index: 0)
        e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: pipe.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }
}
gpu.qualityOfService = .userInitiated; gpu.start()

/// Vision requests that Apple runs on the Neural Engine where it can. Whether they did is what
/// the ANE counters are for; this only supplies the work.
func noise(_ side: Int) -> CGImage {
    var px = [UInt8](repeating: 0, count: side * side * 4)
    for i in 0..<px.count { px[i] = UInt8.random(in: 0...255) }
    let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return ctx.makeImage()!
}
final class Counter: @unchecked Sendable { private let l = NSLock(); private var n = 0
    func bump() { l.lock(); n += 1; l.unlock() }
    var value: Int { l.lock(); defer { l.unlock() }; return n } }
let visionRuns = Counter()
for _ in 0..<4 {
    let t = Thread {
        let img = noise(1024)
        while true {
            let p = phase()
            if p == "done" { return }
            if p != "ane" { usleep(50_000); continue }
            // A pool per batch: without it Vision's results pile up, and the first run of this probe
            // grew by 10 GB in twenty seconds — which then showed up in its own memory columns.
            autoreleasepool {
                let seg = VNGeneratePersonSegmentationRequest(); seg.qualityLevel = .accurate
                let handler = VNImageRequestHandler(cgImage: img, options: [:])
                try? handler.perform([seg, VNClassifyImageRequest(), VNGenerateImageFeaturePrintRequest(), VNDetectHumanBodyPoseRequest()])
            }
            visionRuns.bump()
        }
    }
    t.qualityOfService = .userInitiated; t.start()
}

// MARK: CLPC subscription, built by hand

typealias CopyAll = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
typealias CreateSub = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> UnsafeRawPointer?
typealias CreateSamples = @convention(c) (UnsafeRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
typealias GetInteger = @convention(c) (CFDictionary, Int32) -> Int64
let lib = DynamicLibrary("/usr/lib/libIOReport.dylib")!
let copyAll = lib.symbol("IOReportCopyAllChannels", as: CopyAll.self)!
let createSub = lib.symbol("IOReportCreateSubscription", as: CreateSub.self)!
let createSamples = lib.symbol("IOReportCreateSamples", as: CreateSamples.self)!
let deltaFn = lib.symbol("IOReportCreateSamplesDelta", as: Delta.self)!
let fName = lib.symbol("IOReportChannelGetChannelName", as: GetString.self)!
let fInt = lib.symbol("IOReportSimpleGetIntegerValue", as: GetInteger.self)!
func str(_ u: Unmanaged<CFString>?) -> String { u.map { ($0.takeUnretainedValue() as String).trimmingCharacters(in: .whitespaces) } ?? "" }

let clpcTable: [String: (UInt32, UInt32, UInt32)] = [
    "com.apple.driver.AppleT6000CLPCv3": (0x4747_9059, 0x4519_bf1e, 0x9aaa_17f8), "com.apple.driver.AppleT6002CLPC": (0xb501_816b, 0x9e2c_3e8b, 0x14d5_a574),
    "com.apple.driver.AppleT6020CLPC": (0xe301_cd75, 0x8f34_cc7a, 0x7415_fb0f), "com.apple.driver.AppleT6022CLPC": (0x76f5_fd21, 0x9062_4499, 0x3c09_7307),
    "com.apple.driver.AppleT6030CLPC": (0xbe03_a01a, 0x472d_6c9c, 0xb899_0c38), "com.apple.driver.AppleT6031CLPC": (0xd81e_0084, 0x1085_f98b, 0x313a_3be1),
    "com.apple.driver.AppleT6032CLPC": (0xf4a2_1308, 0x85e8_0513, 0x63dc_8e25), "com.apple.driver.AppleT6041CLPC": (0x263c_f1f0, 0x22e4_cf59, 0x7849_fb5c),
    "com.apple.driver.AppleT6050CLPC": (0xd3ab_60bb, 0x27cd_4ce5, 0x8c0f_1c59), "com.apple.driver.AppleT6050dCLPC": (0x18b3_010e, 0xedec_a11a, 0x188b_d883),
    "com.apple.driver.AppleT8103CLPCv3": (0x2cdd_31f2, 0x21be_cf42, 0x0667_fb81), "com.apple.driver.AppleT8112CLPC": (0xb543_5137, 0x638d_9d52, 0xea08_9c36),
    "com.apple.driver.AppleT8122CLPC": (0x54b5_1c99, 0xce2d_d9dc, 0x960a_fe2f), "com.apple.driver.AppleT8132CLPC": (0x4a85_4d94, 0x3b3e_3b79, 0x1ff4_a9ec),
    "com.apple.driver.AppleT8140CLPC": (0x9bf5_4436, 0xef70_589c, 0x569d_941b), "com.apple.driver.AppleT8142CLPC": (0x4370_8744, 0x6a01_0933, 0xbc5e_fdf0),
    "com.apple.driver.AppleT8152CLPC": (0x485d_4bfc, 0x1178_4654, 0x9380_c6bb),
]
var driverID: UInt64 = 0, bundle = ""
if let it = IOServiceIterator("AppleCLPC") {
    while let (entry, _) = it.next() {
        IORegistryEntryGetRegistryEntryID(entry, &driverID)
        bundle = (ioProperties(entry)?["CFBundleIdentifier"] as? String) ?? ""
        IOObjectRelease(entry)
    }
}
func clpcChannel(_ index: UInt64, _ key: UInt32, _ name: String) -> NSMutableDictionary {
    let id = Int64(bitPattern: (index << 32) | UInt64(key))
    let type: Int64 = 1 | (2 << 16) | (1 << 32), unit: Int64 = (3 << 56) | (118 << 32)
    return NSMutableDictionary(dictionary: [
        "DriverID": NSNumber(value: Int64(bitPattern: driverID)), "DriverName": "AppleCLPC",
        "IOReportGroupName": "CLPC", "IOReportSubGroupName": "Energy Counters",
        "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: unit)],
        "LegendChannel": [NSNumber(value: id), NSNumber(value: type), name],
    ])
}
var clpcSub: (UnsafeRawPointer, NSMutableDictionary)?
if let keys = clpcTable[bundle], ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 {
    let all = copyAll(0, 0)!.takeRetainedValue() as NSDictionary
    let sel = NSMutableArray()
    sel.add(clpcChannel(16, keys.0, "CPU Energy")); sel.add(clpcChannel(25, keys.1, "GPU Energy")); sel.add(clpcChannel(24, keys.2, "ANE"))
    let chan = NSMutableDictionary(dictionary: all); chan["IOReportChannels"] = sel
    var sd: Unmanaged<CFMutableDictionary>?
    if let sub = createSub(nil, chan as CFMutableDictionary, &sd, 0, nil) { clpcSub = (sub, chan) }
}
func clpcRaw() -> (CFDictionary, TimeInterval)? {
    guard let c = clpcSub, let s = createSamples(c.0, c.1 as CFMutableDictionary, nil)?.takeRetainedValue() else { return nil }
    return (s, ProcessInfo.processInfo.systemUptime)
}

// MARK: memory

func sysInt32(_ name: String) -> Int32 { var v: Int32 = -1; var n = MemoryLayout<Int32>.size; sysctlbyname(name, &v, &n, nil, 0); return v }
func swapCounters() -> (UInt64, UInt64) {
    var st = vm_statistics64(); var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &st) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) } }
    return (st.swapins, st.swapouts)
}

// MARK: run

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/stdout"
FileManager.default.createFile(atPath: outPath, contents: nil)
guard let out = FileHandle(forWritingAtPath: outPath), let em = IOReport() else { print("cannot start"); exit(1) }
func emit(_ s: String) { out.write((s + "\n").data(using: .utf8)!) }
emit("# driver \(bundle) id 0x\(String(driverID, radix: 16)) · \(ProcessInfo.processInfo.operatingSystemVersionString) · uid \(getuid()) · clpc \(clpcSub != nil)")
emit(["epoch", "t", "phase", "clpc_cpu", "clpc_gpu", "clpc_ane", "em_cpu", "em_gpu", "em_gpusram", "em_ane", "em_dram", "hist_cpu",
      "mem_level", "free_pct", "used_ratio", "app_gb", "compressed_gb", "cached_gb", "swap_used_gb", "swapin_bps", "swapout_bps", "thermal", "vision_runs"].joined(separator: "\t"))
print("driver \(bundle) · CLPC \(clpcSub != nil ? "subscribed" : "NOT available") · \(Int(total)) s · writing \(outPath)")

_ = em.sampleSincePrevious()
var prevClpc = clpcRaw()
var prevSwap = swapCounters(), prevT = ProcessInfo.processInfo.systemUptime
var tickRate = 0.0
let page = Double(vm_kernel_page_size)
var t = 0
while ProcessInfo.processInfo.systemUptime - started < total {
    Thread.sleep(forTimeInterval: 1); t += 1
    let ph = phase()
    var c: [String: Double] = [:]
    if let p = prevClpc, let n = clpcRaw() {
        if let d = deltaFn(p.0, n.0, nil)?.takeRetainedValue() as NSDictionary?, let arr = d["IOReportChannels"] as? [NSDictionary] {
            for item in arr { let cf = item as CFDictionary; c[str(fName(cf))] = Double(fInt(cf, 0)) / 1e9 / (n.1 - p.1) }
        }
        prevClpc = n
    }
    var emCPU = 0.0, emGPU = 0.0, emSRAM = 0.0, emANE = 0.0, emDRAM = 0.0, hist = -1.0
    if let s = em.sampleSincePrevious() {
        var energy = 0.0, ticks = 0.0, saw = false
        for ch in s.channels {
            if ch.group == "Energy Model" {
                let w = em.watts(ch, elapsed: s.elapsed)
                if ch.name == "GPU Energy" { emGPU += w } else if ch.name.hasPrefix("GPU SRAM") { emSRAM += w }
                else if ch.name.hasSuffix("CPU Energy") { emCPU += w } else if ch.name.hasPrefix("ANE") { emANE += w }
                else if ch.name.hasPrefix("DRAM") { emDRAM += w }
            } else if ch.group == "PMP", IOReport.isClusterHistogram(ch.name) {
                let (e, k) = Sampler.clusterWatts(em.residencies(ch.item)); energy += e; ticks = max(ticks, k); saw = true
            }
        }
        tickRate = max(tickRate, ticks / s.elapsed)
        if saw, tickRate > 0 { hist = energy / (tickRate * s.elapsed) }
    }
    let now = ProcessInfo.processInfo.systemUptime, sw = swapCounters(), m = MemoryStats.read()
    let dt = now - prevT
    let swapIn = Double(sw.0 &- prevSwap.0) * page / dt, swapOut = Double(sw.1 &- prevSwap.1) * page / dt
    prevSwap = sw; prevT = now
    let level = sysInt32("kern.memorystatus_vm_pressure_level"), free = sysInt32("kern.memorystatus_level")
    let gb = 1_073_741_824.0
    let f = { (x: Double) in String(format: "%.3f", x) }
    emit([String(format: "%.2f", Date().timeIntervalSince1970), "\(t)", ph,
          f(c["CPU Energy"] ?? -1), f(c["GPU Energy"] ?? -1), f(c["ANE"] ?? -1), f(emCPU), f(emGPU), f(emSRAM), f(emANE), f(emDRAM), f(hist),
          "\(level)", "\(free)", f(m.usedRatio), f(Double(m.app) / gb), f(Double(m.compressed) / gb), f(Double(m.cached) / gb), f(Double(m.swapUsed) / gb),
          f(swapIn), f(swapOut), "\(ProcessInfo.processInfo.thermalState.rawValue)", "\(visionRuns.value)"].joined(separator: "\t"))
    print(String(format: "%3d/%d  %@  cpu %5.1f W  gpu %5.2f W  ane %5.3f W  · memory level %d, %d%% free", t, Int(total),
                 ph.padding(toLength: 12, withPad: " ", startingAt: 0) as NSString, c["CPU Energy"] ?? -1, c["GPU Energy"] ?? -1, c["ANE"] ?? -1, level, free))
}
print("done · Vision batches \(visionRuns.value)")
exit(0)
