// Threshold sweep. Build and run:
//   swiftc -O Sources/Core/*.swift Tools/thresholds/main.swift -o /tmp/thresholds && /tmp/thresholds
//
// Snapshot.channels() is the single source for every health band in the interface. This asserts
// it grades identically to the individual *Health properties across every reachable value. It
// earns its keep: it caught the memory channel turning hot one step early, because `pressure` is
// an integer and `< 45` is not `<= 45`.
import Foundation
// Sweep every channel's driving reading and assert the new single-source band matches the old
// per-property grading exactly. A silent threshold shift is the one regression this refactor
// could plausibly cause and the one nobody would notice.
var bad = 0, checked = 0
func check(_ what: String, _ v: Double, _ old: Health, _ new: Health) {
    checked += 1
    if old != new { bad += 1; print("  MISMATCH \(what) at \(v): was \(old), now \(new)") }
}
let chip = "Max"
for i in 0...4000 {
    var s = Snapshot()
    let t = Double(i) / 20                      // 0 … 200
    s.cpuTempMax = t; s.gpuTemp = t; s.ssdTemp = t
    s.sysPower = t; s.memory.total = 4000; s.memory.used = UInt64(i)
    s.memory.pressure = 100 - i / 40
    let ch = s.channels(chipClass: chip)
    check("cpu", t, s.cpuTempMaxHealth, ch[Channel.cpu.rawValue].band)
    check("gpu", t, s.gpuTempHealth, ch[Channel.gpu.rawValue].band)
    check("ssd", t, s.ssdTempHealth, ch[Channel.ssd.rawValue].band)
    check("mem", Double(i), s.memoryHealth, ch[Channel.memory.rawValue].band)
    // power: battery absent, so the channel is pure power
    check("pwr", t, s.powerHealth(chipClass: chip), ch[Channel.power.rawValue].band)
    check("overall", t, [s.cpuTempMaxHealth, s.gpuTempHealth, s.ssdTempHealth, s.memoryHealth,
                         s.powerHealth(chipClass: chip), s.batteryHealth].max() ?? .calm,
          s.overall(chipClass: chip))
}
// battery folds into the power channel: sweep charge and temperature too
for i in 0...100 {
    for ext in [true, false] {
        var s = Snapshot()
        s.battery.present = true; s.battery.percent = i; s.battery.externalPower = ext
        s.battery.temperature = Double(i) / 2 + 10          // 10 … 60 C
        let want = max(s.powerHealth(chipClass: chip), s.batteryHealth)
        check("pwr+batt(ext:\(ext))", Double(i), want, s.channels(chipClass: chip)[Channel.power.rawValue].band)
    }
}

// fill must rise monotonically with the reading, and cross 0.72 exactly at warm, 1.0 at hot
var prev = -1.0
for i in 0...920 {
    var s = Snapshot(); s.cpuTempMax = Double(i) / 10
    let f = s.channels(chipClass: chip)[Channel.cpu.rawValue].fill
    if f < prev - 1e-9 { bad += 1; print("  fill went backwards at \(Double(i)/10) °C") }
    prev = f
}
var s75 = Snapshot(); s75.cpuTempMax = 75
var s92 = Snapshot(); s92.cpuTempMax = 92
let f75 = s75.channels(chipClass: chip)[Channel.cpu.rawValue].fill
let f92 = s92.channels(chipClass: chip)[Channel.cpu.rawValue].fill
print(String(format: "  fill at the warm threshold (75 °C): %.4f  (must be 0.7200)", f75))
print(String(format: "  fill at the hot threshold  (92 °C): %.4f  (must be 1.0000)", f92))
if abs(f75 - 0.72) > 1e-9 || abs(f92 - 1.0) > 1e-9 { bad += 1 }
print(bad == 0 ? "✓ \(checked) gradings checked, every threshold preserved"
               : "✗ \(bad) mismatches out of \(checked)")
exit(bad == 0 ? 0 : 1)
