// What a sample costs, measured the way the app takes one. Build and run:
//   swiftc -O Sources/Core/*.swift Tools/bench/main.swift -o /tmp/bench && /tmp/bench
//
// On a `.utility` queue, one sample every two seconds, counting CPU time on the sampling thread.
// Until 1.6.0 this was a tight loop timed by the wall clock, and it was wrong twice over. A loop
// runs on a performance core at full clock, where the app's own queue is handed an efficiency core
// at whatever it is idling at: the same `sample()` read 8.9 ms of CPU in the loop and 19.7 ms in
// the app. And the wall clock counts the 28 ms a sample spends waiting on the SMC, which costs
// nothing. The README quoted 1.3 ms for the process table from that loop; in the app it was 5.3.
//
// Takes about a minute and a half. Run it on a quiet machine — a busy one moves the queue to
// faster cores and flatters every figure.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func threadCPU() -> Double {
    var ts = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1e6
}

guard let sampler = Sampler() else { print("hardware sources unavailable (Apple Silicon required)"); exit(1) }
print(sampler.sourcesDescription)

let interval = 2.0, ticks = 12
let queue = DispatchQueue(label: "bench", qos: .utility)

/// CPU and wall milliseconds per sample, on the app's queue and at the app's spacing.
func measure(_ name: String, _ body: @escaping () -> Void) {
    let done = DispatchSemaphore(value: 0)
    queue.async {
        body()                                       // settle: first use opens connections
        var cpu = 0.0, wall = 0.0
        for _ in 0..<ticks {
            Thread.sleep(forTimeInterval: interval)
            let c0 = threadCPU(), w0 = ProcessInfo.processInfo.systemUptime
            body()
            cpu += threadCPU() - c0
            wall += (ProcessInfo.processInfo.systemUptime - w0) * 1000
        }
        let n = Double(ticks)
        print("  " + name.padding(toLength: 34, withPad: " ", startingAt: 0)
              + String(format: "cpu %5.1f ms   wall %5.1f ms   %.2f%% of a core at %.0f s",
                       cpu / n, wall / n, cpu / n / (interval * 1000) * 100, interval))
        done.signal()
    }
    done.wait()
}

let ports = machPortCount()
measure("panel closed") { _ = sampler.sample(interval: interval, detail: false) }
measure("panel open") { _ = sampler.sample(interval: interval, detail: true) }
measure("panel open, all sensors") { _ = sampler.sample(interval: interval, allSensors: true, detail: true) }
print("  Mach ports: \(ports) before, \(machPortCount()) after")

// Does the live-key subset still see the same peak as a full sweep?
let live = sampler.sample(interval: 0), full = sampler.sample(interval: 0, allSensors: true)
print(String(format: "\nCPU max  live %.1f  vs full %.1f  (Δ %.2f)", live.cpuTempMax, full.cpuTempMax, live.cpuTempMax - full.cpuTempMax))
print(String(format: "CPU avg  live %.1f  vs full %.1f  (Δ %.2f)", live.cpuTemp, full.cpuTemp, live.cpuTemp - full.cpuTemp))
print(String(format: "GPU avg  live %.1f  vs full %.1f  (Δ %.2f)", live.gpuTemp, full.gpuTemp, live.gpuTemp - full.gpuTemp))
print(String(format: "SSD      live %.1f  vs full %.1f", live.ssdTemp, full.ssdTemp))
