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

// ── a magnitude on its threshold holds its band (1.6.0) ──
// The recording that prompted this: the hottest core at 94–96 °C under a steady load, and the
// verdict changing nine times in forty seconds. Replay a reading that hovers and count the changes.
print("── a reading hovering on its threshold ──")
func bands(_ temps: [Double], holding: Bool) -> [Health] {
    var held: Set<Magnitude> = [], out: [Health] = []
    for t in temps {
        var s = Snapshot(); s.cpuTempMax = t
        if holding { held = s.holding(after: held, chipClass: chip); s.held = held }
        let band = s.channels(chipClass: chip)[Channel.cpu.rawValue].band
        // The mark, the menu-bar figure and the THERMALS row all read the same latch.
        require(band == s.cpuTempMaxHealth, "held: channel says \(band.word), the reading's own grade says \(s.cpuTempMaxHealth.word) at \(t) °C")
        out.append(band)
    }
    return out
}
func changes(_ b: [Health]) -> Int { zip(b, b.dropFirst()).filter { $0 != $1 }.count }
let hover: [Double] = [93.8, 95.2, 94.6, 95.4, 94.1, 95.0, 94.9, 95.6, 94.3, 95.1, 94.7, 92.4, 91.5, 90.0]
let loose = bands(hover, holding: false), firm = bands(hover, holding: true)
print("  \(hover.count) samples between 90 and 96 °C: \(changes(loose)) band changes without the hold, \(changes(firm)) with it")
require(changes(loose) >= 8, "the replay no longer reproduces the flicker it was written from")
require(changes(firm) == 2, "held: expected calm → warm → calm, got \(changes(firm)) changes")
require(firm[1] == .warm && firm[10] == .warm, "held: warm must last while the reading stays above the release line")
require(firm[11] == .warm, "held: 92.4 °C is inside the 3 °C release margin and must still be warm")
require(firm[12] == .calm, "held: 91.5 °C is clear of the margin and must let go")
var heldFill = Snapshot(); heldFill.cpuTempMax = 93; heldFill.held = [.cpuTempMax]
require(abs(heldFill.channels(chipClass: chip)[Channel.cpu.rawValue].fill - Health.warmMark) < 1e-9, "a held feather must stand on the warm mark")
// Holding never lifts anything to hot, and never applies to a reading that was not warm before.
var coldStart = Snapshot(); coldStart.cpuTempMax = 93
require(coldStart.holding(after: [], chipClass: chip).isEmpty, "93 °C that was never warm must not be held")
var heldAll = Snapshot(); heldAll.held = Set(Magnitude.allCases)
require(heldAll.overall(chipClass: chip) == .warm, "every magnitude held must read warm, not hot")
// Power: warm from 85 % of the envelope, released under 80 %.
let env = Snapshot.powerEnvelope(chip)
var pw = Snapshot(); pw.sysPower = env * 0.82
require(pw.holding(after: [.power], chipClass: chip) == [.power], "power at 82 % of the envelope stays held")
pw.sysPower = env * 0.79
require(pw.holding(after: [.power], chipClass: chip).isEmpty, "power at 79 % of the envelope lets go")

// ── network: differences of 32-bit counters, and which link is named (1.6.0) ──
print("── network counters ──")
func moved(_ a: UInt32, _ b: UInt32, _ pa: UInt32, _ pb: UInt32) -> UInt64 { NetworkSampler.moved(from: a, to: b, packetsFrom: pa, to: pb) }
require(moved(1_000, 5_000, 10, 14) == 4_000, "an ordinary difference")
require(moved(100, 3_500_000_100, 10, 2_400_000) == 3_500_000_000, "a fast link moving most of the counter's range in one interval is still counted")
require(moved(4_294_967_000, 704, 900_000, 900_001) == 1_000, "a counter that wrapped past 2^32 still moved 1,000 bytes")
require(moved(3_500_000_000, 12, 2_400_000, 1) == 0, "bytes and packets both fell: the adapter was reset, and that is not traffic")
require(moved(1_000_000_000, 12, 700_000, 0) == 0, "a reset from a low count is not traffic either")
require(["en0", "en13", "awdl0", "llw0", "pdp_ip0"].allSatisfy(NetworkSampler.counts), "physical links are counted")
require(!["lo0", "utun4", "bridge0", "anri2", "ap1", "anpi0", "gif0", "stf0", "ipsec0", "vmenet0", "nan0"].contains(where: NetworkSampler.counts),
        "tunnels, bridges and relays ride on a link that is already counted")
func pick(_ cur: String, _ c: [String], _ a: [String: Double]) -> String { NetworkSampler.choose(current: cur, candidates: c, activity: a) }
require(pick("", ["en0", "en5"], [:]) == "en0", "with nothing moving, the first link with an address")
require(pick("en0", ["en0", "en5"], ["en0": 900, "en5": 3_000]) == "en0", "idle chatter does not move the name")
require(pick("en0", ["en0", "en5"], ["en0": 40_000, "en5": 60_000]) == "en0", "a link has to be clearly out-carried")
require(pick("en0", ["en0", "en5"], ["en0": 40_000, "en5": 900_000]) == "en5", "the link doing the work is named")
require(pick("en0", ["en5"], ["en5": 0]) == "en5", "a link that has gone is not named")
require(pick("en0", [], [:]) == "", "no link, no name")
require(pick("", ["en0", "bridge0"], [:]) == "en0", "a bridge is named only when nothing else has an address")
require(pick("", ["bridge0"], [:]) == "bridge0", "a Mac whose only network is the Thunderbolt bridge still shows its address")
print("  wrap, reset, link filter and the choice of link all hold")

print(bad == 0 ? "✓ \(checked) assertions, magnitudes capped and verdicts intact"
               : "✗ \(bad) failures out of \(checked)")
exit(bad == 0 ? 0 : 1)
