// Threshold sweep. Build and run:
//   swiftc -O Sources/Core/*.swift Tools/thresholds/main.swift -o /tmp/thresholds && /tmp/thresholds
//
// Snapshot.channels() is the single source for every health band in the interface. This asserts it
// grades identically to the individual *Health properties across every reachable value, and — since
// 1.3.0 — that the magnitude/verdict split actually holds.
//
// It earns its keep twice over now. It caught the memory channel turning hot one step early,
// because `pressure` is an integer and `< 45` is not `<= 45`. And when the temperature and power
// thresholds were re-cut it failed on the two calibration anchors, which is exactly the moment a
// silent shift would otherwise have slipped through.
import Foundation

var bad = 0, checked = 0
func check(_ what: String, _ v: Double, _ old: Health, _ new: Health) {
    checked += 1
    if old != new { bad += 1; print("  MISMATCH \(what) at \(v): was \(old), now \(new)") }
}
func require(_ ok: Bool, _ msg: @autoclosure () -> String) {
    checked += 1
    if !ok { bad += 1; print("  \(msg())") }
}
let chip = "Max"

// ── channels() agrees with the per-property grading, across every reachable reading ──
for state in ThermalState.allCases {
    for i in 0...4000 {
        var s = Snapshot()
        let t = Double(i) / 20                      // 0 … 200
        s.thermal = state
        s.cpuTempMax = t; s.gpuTemp = t; s.ssdTemp = t
        s.sysPower = t; s.memory.total = 4000; s.memory.used = UInt64(i)
        s.memory.pressure = 100 - i / 40
        let ch = s.channels(chipClass: chip)
        // The two die channels take the worse of their own reading and what macOS says.
        check("cpu/\(state)", t, max(s.cpuTempMaxHealth, state.health), ch[Channel.cpu.rawValue].band)
        check("gpu/\(state)", t, max(s.gpuTempHealth, state.health), ch[Channel.gpu.rawValue].band)
        check("ssd/\(state)", t, s.ssdTempHealth, ch[Channel.ssd.rawValue].band)
        check("mem/\(state)", Double(i), s.memoryHealth, ch[Channel.memory.rawValue].band)
        // power: battery absent, so the channel is pure power
        check("pwr/\(state)", t, s.powerHealth(chipClass: chip), ch[Channel.power.rawValue].band)
    }
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

// ── the property this whole redesign exists to hold ──
//
// A magnitude may never turn the panel coral. Die temperature and watts are graded against numbers
// we chose, and the numbers we chose were measured wrong: 92 °C called an M4 Max hot through 147
// consecutive samples of ordinary sustained work while macOS never said worse than `fair`. Amber
// arriving early is a cosmetic error. Coral arriving early teaches the reader to ignore coral.
print("── no magnitude may reach hot ──")
var worstTemp = Health.calm, worstPower = Health.calm
for i in 0...4000 {
    var s = Snapshot()                                  // thermal defaults to .nominal
    s.cpuTempMax = Double(i) / 20                       // 0 … 200 °C
    s.gpuTemp = s.cpuTempMax
    s.sysPower = Double(i) / 10                         // 0 … 400 W
    let ch = s.channels(chipClass: chip)
    worstTemp = max(worstTemp, max(ch[Channel.cpu.rawValue].band, ch[Channel.gpu.rawValue].band))
    worstPower = max(worstPower, ch[Channel.power.rawValue].band)
}
require(worstTemp != .hot, "temperature alone reached HOT — a guessed threshold is raising a false alarm")
require(worstPower != .hot, "power alone reached HOT — a guessed envelope is raising a false alarm")
print("  0–200 °C with macOS nominal: worst band \(worstTemp.word)")
print("  0–400 W  with no battery:    worst band \(worstPower.word)")

// ── verdicts still must reach hot, or the panel has gone blind ──
print("── verdicts still reach hot ──")
func band(_ build: (inout Snapshot) -> Void, _ c: Channel) -> Health {
    var s = Snapshot(); build(&s); return s.channels(chipClass: chip)[c.rawValue].band
}
let verdicts: [(String, Health, Health)] = [
    ("macOS thermalState serious", .warm, band({ $0.thermal = .serious }, .cpu)),
    ("macOS thermalState critical", .hot, band({ $0.thermal = .critical }, .cpu)),
    ("macOS thermalState critical (gpu)", .hot, band({ $0.thermal = .critical }, .gpu)),
    ("memory pressure critical", .hot, band({ $0.memory.pressure = 20; $0.memory.total = 100 }, .memory)),
    ("SSD past its rated 68 °C", .hot, band({ $0.ssdTemp = 70 }, .ssd)),
    ("battery outside 42 °C", .hot, band({ $0.battery.present = true; $0.battery.temperature = 45 }, .power)),
    ("battery below 10 %, unplugged", .hot, band({ $0.battery.present = true; $0.battery.percent = 5 }, .power)),
]
for (name, want, got) in verdicts {
    require(want == got, "\(name): expected \(want.word), got \(got.word)")
    print("  \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(got.word)")
}

// ── fill rises monotonically and lands on its anchors ──
var prev = -1.0
for i in 0...2000 {
    var s = Snapshot(); s.cpuTempMax = Double(i) / 10
    let f = s.channels(chipClass: chip)[Channel.cpu.rawValue].fill
    if f < prev - 1e-9 { bad += 1; print("  fill went backwards at \(Double(i) / 10) °C") }
    prev = f
}
var atWarm = Snapshot(); atWarm.cpuTempMax = Snapshot.tempWarm
let fWarm = atWarm.channels(chipClass: chip)[Channel.cpu.rawValue].fill
var atCritical = Snapshot(); atCritical.thermal = .critical
let fCrit = atCritical.channels(chipClass: chip)[Channel.cpu.rawValue].fill
print(String(format: "── fill at the warm anchor (%.0f °C): %.4f  (must be 0.7200)", Snapshot.tempWarm, fWarm))
print(String(format: "── fill at thermalState critical:   %.4f  (must be 1.0000)", fCrit))
require(abs(fWarm - 0.72) < 1e-9, "warm anchor moved")
require(abs(fCrit - 1.0) < 1e-9, "critical no longer fills the feather")

// ── the cluster-histogram reduction behind CPU power on macOS 27 ──
// States are named by their upper edge; a band counts at its midpoint. Two equal residencies in
// the first two 0.25 W bands must average 0.25 W, and a label that is not a wattage is skipped.
let (w1, t1) = Sampler.clusterWatts([(" 0.250W", 10), (" 0.500W", 10), ("OFF", 99)])
require(abs(w1 / t1 - 0.25) < 1e-9 && t1 == 20, "cluster histogram: expected 0.25 W over 20 ticks, got \(w1 / t1) over \(t1)")
let (w2, t2) = Sampler.clusterWatts([("   2W", 0), ("   4W", 5), ("   6W", 5)])
require(abs(w2 / t2 - 4) < 1e-9, "cluster histogram: 2 W bands, expected 4 W, got \(w2 / t2)")

// ── which CPU power figure is printed ──
// The case that shipped as a spike: a live counter carrying a batch, 21.69 W against a histogram
// near 12. And the cases that must not change: an honest counter within the histogram's margin,
// the histogram alone, and neither.
func src(_ c: Double, _ l: Bool, _ h: Double?) -> (Double, PowerSource) { Sampler.cpuPower(counter: c, counterLive: l, histogram: h) }
require(src(21.69, true, 12.07) == (12.07, .clusterHistogram), "a batch-laden counter sample must fall back to the histogram")
require(src(11.0, true, 12.2) == (11.0, .energyModel), "an honest live counter must win")
require(src(1.2, true, 2.5) == (1.2, .energyModel), "at idle the histogram reads high; the counter must still win")
require(src(1.8, true, 0.9) == (1.8, .energyModel), "near idle a counter above the histogram stays inside the 2 W margin")
require(src(0, false, 7.5) == (7.5, .clusterHistogram), "no live counter: histogram")
require(src(40, true, nil) == (40, .energyModel), "no histogram on this machine: trust the counter")
require(src(0, false, nil) == (0, .none), "neither: nothing to report")

print(bad == 0 ? "✓ \(checked) assertions, magnitudes capped and verdicts intact"
               : "✗ \(bad) failures out of \(checked)")
exit(bad == 0 ? 0 : 1)
