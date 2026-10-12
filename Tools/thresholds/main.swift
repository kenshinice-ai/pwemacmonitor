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
    ("macOS memory pressure warning", .warm, band({ $0.memory.level = .warning }, .memory)),
    ("macOS memory pressure critical", .hot, band({ $0.memory.level = .critical }, .memory)),
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

// ── memory follows macOS's level and nothing else (1.7.0) ──
// The requirement in one line: with the system at normal, no amount of memory in use and no
// free-memory percentage may colour the channel. Until 1.7.0 "free below 45 %" was coral and
// "over 85 % used" was amber, on quantities the kernel does not decide the level from.
print("── memory: the system's level decides ──")
var memChecked = 0
for used in stride(from: 0, through: 1000, by: 5) {
    for free in stride(from: 0, through: 100, by: 5) {
        var s = Snapshot(); s.memory.total = 1000; s.memory.used = UInt64(used); s.memory.pressure = free
        for level in [MemoryPressure.normal, .warning, .critical] {
            s.memory.level = level
            let ch = s.channels(chipClass: chip)[Channel.memory.rawValue]
            require(ch.band == level.health, "memory at \(used / 10) % used, \(free) % free, level \(level.key): band \(ch.band.word)")
            require(s.memoryHealth == ch.band, "memoryHealth and the channel disagree at level \(level.key)")
            if level == .normal { require(ch.fill < Health.warmMark, "a normal level reached the warm mark at \(used / 10) % used") }
            memChecked += 1
        }
        s.memory.level = nil
        require(s.channels(chipClass: chip)[Channel.memory.rawValue].band == .calm, "an unreadable level must be calm, not a guess")
    }
}
var mw = Snapshot(); mw.memory.level = .warning
var mc = Snapshot(); mc.memory.level = .critical
require(abs(mw.channels(chipClass: chip)[Channel.memory.rawValue].fill - Health.warmMark) < 1e-9, "warning stands on the warm mark")
require(abs(mc.channels(chipClass: chip)[Channel.memory.rawValue].fill - 1) < 1e-9, "critical fills the feather")
require(MemoryPressure(rawValue: 1) == .normal && MemoryPressure(rawValue: 2) == .warning && MemoryPressure(rawValue: 4) == .critical
        && MemoryPressure(rawValue: 3) == nil && MemoryPressure(rawValue: -1) == nil, "the sysctl answers 1, 2 or 4; anything else is unknown")
print("  \(memChecked) combinations of used, free and level: the level alone sets the band")

// ── how long the pressure has lasted ──
var clock = PressureClock()
clock.update(.normal, now: 100); require(clock.seconds == nil && clock.text == nil, "normal: no spell")
clock.update(.warning, now: 110); clock.update(.warning, now: 170)
require(clock.seconds == 60 && clock.startKnown, "a spell that began while we watched is counted from its start")
clock.update(.critical, now: 400)
require(clock.seconds == 290, "warning rising to critical does not start the count again")
clock.update(nil, now: 410)
require(clock.seconds == 300, "an unreadable level is not the pressure ending")
clock.update(.normal, now: 500)
require(clock.seconds == nil && clock.lastSeconds == 390 && clock.lastEnded == 500, "back to normal: the spell is closed and remembered")
var late = PressureClock()
late.update(.warning, now: 50); late.update(.warning, now: 770)
require(!late.startKnown && late.seconds == 720, "pressure already on at launch: the start is not known")
require(late.text?.hasSuffix("+") == true, "…and the figure is printed as a floor, got \(late.text ?? "nil")")
late.update(.normal, now: 800); late.update(.warning, now: 900)
require(late.startKnown, "the next spell is one we saw begin")
require(PressureClock.format(45) == "45s" && PressureClock.format(725) == "12m" && PressureClock.format(4330) == "1h 12m", "durations: 45s, 12m, 1h 12m")
print("  spell start, escalation, unreadable level, end, and a start we did not see")

// ── the verdict line ──
let warnCh = mw.channels(chipClass: chip)
mw.pressure = clock                                       // normal again: no duration
require(warnCh.headline(memory: "Memory pressure warning · 12m") == "Memory pressure warning · 12m", "memory's clause is the system's verdict, not a percentage")
require(!warnCh.headline(memory: "Memory pressure warning · 12m").contains("%"), "no '72 % to its limit' for a level")
require(Snapshot().channels(chipClass: chip).headline(primed: false) == "Reading…", "nothing is called calm before the first interval is measured")
require(Snapshot().channels(chipClass: chip).headline() == "All five channels calm", "…and after it, calm is calm")
var held12 = Snapshot(); held12.memory.level = .warning
var c12 = PressureClock(); c12.update(.normal, now: 0); c12.update(.warning, now: 10); c12.update(.warning, now: 730); held12.pressure = c12
require(held12.memoryVerdict == "Memory pressure warning · 12m", "memoryVerdict: got \(held12.memoryVerdict ?? "nil")")
require(Snapshot().memoryVerdict == nil, "no memory clause while the level is normal")
// macOS throttling for heat does not explain a shortage of memory: both are said.
let both = warnCh.headline(thermal: .serious, memory: "Memory pressure warning · 12m")
require(both.contains("Performance reduced") && both.contains("Memory pressure warning"), "thermal serious must not hide the memory verdict, got: \(both)")
var hotDie = Snapshot(); hotDie.thermal = .serious
require(!hotDie.channels(chipClass: chip).headline(thermal: .serious).contains("CPU"), "…but the die channels it lifts are still said once, not twice")
var unseen = PressureClock(); unseen.update(.warning, now: 5); unseen.update(.normal, now: 65)
require(unseen.lastSeconds == 60 && !unseen.lastStartKnown, "a spell whose start was not seen is remembered as a floor")

// ── the CLPC witness (1.7.0) ──
// The pairs measured 2026-10-12, which must agree; and counters that are not the CPU's, which must not.
print("── CLPC witness ──")
for (c, h) in [(1.62, 1.62), (23.08, 22.72), (2.51, 2.29), (0.93, 1.06), (8.36, 6.82)] {
    require(Sampler.clpcAgrees(clpc: c, histogram: h), "measured pair \(c) W / \(h) W must agree")
}
require(!Sampler.clpcAgrees(clpc: 41.5, histogram: 1.1), "a GPU's counter read as the CPU's must be refused")
require(!Sampler.clpcAgrees(clpc: 0.0, histogram: 22.7), "a counter that does not move under load must be refused")
require(!Sampler.clpcAgrees(clpc: 3.6, histogram: 0.9), "the ANE's counter read as the CPU's must be refused")
require(!Sampler.clpcAgrees(clpc: -1, histogram: 1), "a negative reading is not a reading")
for (c, h) in [(0.72, 0.92), (0.84, 1.03), (1.02, 1.16), (1.47, 1.51), (1.09, 1.21)] {
    require(Sampler.clpcAgrees(clpc: c, histogram: h), "quiet pair \(c) W / \(h) W must agree")
}
require(!Sampler.clpcAgrees(clpc: 0, histogram: 1.2), "on an idle Mac a counter reading nothing must still be refused")
require(!Sampler.clpcAgrees(clpc: 0.14, histogram: 0.92), "…and so must the GPU's counter, idling at a seventh of a watt")
require(!Sampler.clpcAgrees(clpc: 2.6, histogram: 1.5), "…and one reading a watt too many")
require(CLPC.reportIDs(bundle: "com.apple.driver.AppleT6041CLPC", osMajor: 27)! == (0x0000_0010_263c_f1f0, 0x0000_0019_22e4_cf59, 0x0000_0018_7849_fb5c), "M4 Max, macOS 27: the IDs macmon lists")
require(CLPC.reportIDs(bundle: "com.apple.driver.AppleT6041CLPC", osMajor: 26) == nil && CLPC.reportIDs(bundle: "com.apple.driver.AppleT6041CLPC", osMajor: 28) == nil,
        "the table is for macOS 27 and says nothing about any other")
require(CLPC.reportIDs(bundle: "com.apple.driver.AppleUnknownCLPC", osMajor: 27) == nil, "an unknown driver gets no IDs, not a guess")

// ── the GPU witness, and the CPU rail on a Mac with no histograms (1.7.1) ──
// An M3 and an M5 Max list no cluster histograms: 1.7.0 showed no CPU power there and never let
// the Neural Engine through. There the GPU pair stands witness. The pairs measured 2026-10-12.
print("── GPU witness ──")
for (c, g) in [(20.18, 20.17), (5.17, 5.07), (6.25, 5.81), (22.03, 21.70), (37.77, 37.78), (39.52, 39.51)] {
    require(Sampler.gpuAgrees(clpc: c, counter: g), "measured GPU pair \(c) W / \(g) W must agree")
}
require(!Sampler.gpuAgrees(clpc: 0.51, counter: 0.24), "a GPU at rest is not judged: every idle counter looks alike beside it")
require(!Sampler.gpuAgrees(clpc: 0.0, counter: 3.1), "the ANE's counter, at rest, read as the GPU's must be refused")
require(!Sampler.gpuAgrees(clpc: 9.4, counter: 3.1), "the CPU's counter read as the GPU's must be refused")
require(!Sampler.gpuAgrees(clpc: 1.2, counter: 51), "a counter that does not follow the GPU under load must be refused")
require(Sampler.gpuAgrees(clpc: 2.0, counter: 1.5) && !Sampler.gpuAgrees(clpc: 2.4, counter: 1.5), "at the floor the margin is three quarters of a watt")
require(CLPC.reportIDs(bundle: "com.apple.driver.AppleT8122CLPC", osMajor: 27)!.gpu == 0x0000_0019_ce2d_d9dc, "M3, macOS 27: the GPU ID macmon lists")
require(CLPC.reportIDs(bundle: "com.apple.driver.AppleT6050CLPC", osMajor: 27)!.gpu == 0x0000_0019_27cd_4ce5, "M5 Max, macOS 27: the GPU ID macmon lists")
let (viaCLPC, viaCLPCSource) = Sampler.cpuPower(counter: 0, counterLive: false, histogram: nil, clpc: 6.3)
require(viaCLPC == 6.3 && viaCLPCSource == .clpc, "no histograms and a witnessed table: the CPU rail is CLPC's")
require(Sampler.cpuPower(counter: 0, counterLive: false, histogram: 7.1, clpc: 7.5).1 == .clusterHistogram, "where the histograms exist they still win")
require(Sampler.cpuPower(counter: 0, counterLive: false, histogram: nil, clpc: nil).1 == .none, "no histograms and no witness: no figure")
print("  five measured pairs agree; a wrong counter, a dead one and another OS are refused")

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
