// Thermal calibration probe. Build and run:
//   swiftc -O -swift-version 5 Sources/Core/*.swift Tools/thermalprobe/main.swift \
//     -o /tmp/thermalprobe -framework IOKit -framework Metal
//   /tmp/thermalprobe 240 60        # 240 s of load, then 60 s watching it fall
//
// WARNING: this pins every core and the GPU. The fans will be loud and the machine will get hot.
// That is the point — it is the only way to see what a chip actually does at its ceiling.
//
// It answers one question: does this machine cross the temperature the CPU/GPU feathers call hot
// while macOS still reports a nominal thermal state? On an M4 Max in 2026-09 the answer was yes,
// on 147 samples out of 147, which is why magnitudes no longer reach coral — see
// docs/thermal-verdict.md. Compiled against Sources/Core so it grades with the shipping code.
//
// It measures whatever else is running too. Check what is busy before reading a baseline: the
// first run of this was taken on a Mac that was rendering video throughout, and its cooldown
// phase never cooled.
import Foundation
import Metal

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered: this runs for minutes and is watched live

let loadSeconds = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "240") ?? 240
let coolSeconds = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "60") ?? 60

final class Flag: @unchecked Sendable {
    private let l = NSLock(); private var v = true
    var on: Bool { get { l.lock(); defer { l.unlock() }; return v }
                   set { l.lock(); v = newValue; l.unlock() } }
}
let running = Flag()

// CPU: one thread per active core, floating-point work the optimiser cannot elide.
for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
    let t = Thread {
        var a = 1.0, b = 1.0000001
        while running.on {
            for _ in 0..<2_000_000 { a = a * b + 1e-9; if a > 1e12 { a = 1.0 } }
        }
    }
    t.qualityOfService = .userInitiated
    t.start()
}

// GPU: a compute kernel of dependent FMAs, redispatched until told to stop.
let gpuThread = Thread {
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
    guard let lib = try? dev.makeLibrary(source: src, options: nil),
          let fn = lib.makeFunction(name: "burn"),
          let pipe = try? dev.makeComputePipelineState(function: fn),
          let buf = dev.makeBuffer(length: 1 << 22, options: .storageModePrivate) else {
        FileHandle.standardError.write("GPU load unavailable\n".data(using: .utf8)!); return
    }
    let n = (1 << 22) / MemoryLayout<Float>.size
    while running.on {
        guard let cb = q.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { break }
        e.setComputePipelineState(pipe); e.setBuffer(buf, offset: 0, index: 0)
        e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: pipe.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }
}
gpuThread.qualityOfService = .userInitiated
gpuThread.start()

guard let sampler = Sampler() else { fputs("no sampler\n", stderr); exit(1) }
let cls = sampler.soc.chipClass
func thermal() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"; case .fair: return "fair"
    case .serious: return "SERIOUS"; case .critical: return "CRITICAL"; @unknown default: return "?" }
}
func band(_ h: Health) -> String { ["calm", "warm", "HOT"][h.rawValue] }

print("\(sampler.soc.chipName) · \(cls) · load \(Int(loadSeconds))s then \(Int(coolSeconds))s cooling\n")
print("   t  phase  cpuMax  cpuAvg   gpu   sysW  fans    thermalState  cpuBand gpuBand pwrBand")
_ = sampler.sample(interval: 1, allSensors: false)
var peakCPU = 0.0, peakGPU = 0.0, peakW = 0.0
var everNonNominal = false, hotWhileNominal = 0, samples = 0
let t0 = Date()
while Date().timeIntervalSince(t0) < loadSeconds + coolSeconds {
    Thread.sleep(forTimeInterval: 2)
    let el = Date().timeIntervalSince(t0)
    if el >= loadSeconds && running.on { running.on = false; print("   —— load off ——") }
    let s = sampler.sample(interval: 2, allSensors: false)
    let ch = s.channels(chipClass: cls)
    let st = thermal()
    if st != "nominal" { everNonNominal = true }
    peakCPU = max(peakCPU, s.cpuTempMax); peakGPU = max(peakGPU, s.gpuTemp); peakW = max(peakW, s.sysPower)
    let cpuB = band(ch[4].band), gpuB = band(ch[3].band), pwrB = band(ch[2].band)
    if st == "nominal" && (cpuB == "HOT" || gpuB == "HOT") { hotWhileNominal += 1 }
    samples += 1
    print(String(format: "%4.0fs  %@  %6.1f  %6.1f  %5.1f  %5.1f  %4d    %-9@     %-6@  %-6@  %@",
                 el, el < loadSeconds ? "LOAD " : "cool ", s.cpuTempMax, s.cpuTemp, s.gpuTemp, s.sysPower,
                 s.fans.map(\.rpm).max() ?? 0, st as NSString, cpuB as NSString, gpuB as NSString, pwrB as NSString))
}
running.on = false
print(String(format: "\npeak  cpuMax %.1f °C   gpu %.1f °C   sys %.1f W", peakCPU, peakGPU, peakW))
print("thermalState ever left nominal: \(everNonNominal ? "yes" : "NO")")
print("samples graded HOT by temperature while macOS said nominal: \(hotWhileNominal) of \(samples)")
