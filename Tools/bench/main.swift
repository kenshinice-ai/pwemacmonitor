import Foundation

func bench(_ name: String, _ n: Int = 25, _ body: () -> Void) {
    body()
    let t0 = ProcessInfo.processInfo.systemUptime
    for _ in 0..<n { body() }
    print(String(format: "  %-32@ %6.2f ms", name as NSString, (ProcessInfo.processInfo.systemUptime - t0) / Double(n) * 1000))
}

guard let sampler = Sampler() else { exit(1) }
print(sampler.sourcesDescription)
bench("sample() — normal") { _ = sampler.sample(interval: 0) }
bench("sample(allSensors:) — panel open") { _ = sampler.sample(interval: 0, allSensors: true) }

// Does the live-key subset still see the same peak as a full sweep?
let live = sampler.sample(interval: 0), full = sampler.sample(interval: 0, allSensors: true)
print(String(format: "\nCPU max  live %.1f  vs full %.1f  (Δ %.2f)", live.cpuTempMax, full.cpuTempMax, live.cpuTempMax - full.cpuTempMax))
print(String(format: "CPU avg  live %.1f  vs full %.1f  (Δ %.2f)", live.cpuTemp, full.cpuTemp, live.cpuTemp - full.cpuTemp))
print(String(format: "GPU avg  live %.1f  vs full %.1f  (Δ %.2f)", live.gpuTemp, full.gpuTemp, live.gpuTemp - full.gpuTemp))
print(String(format: "SSD      live %.1f  vs full %.1f", live.ssdTemp, full.ssdTemp))
