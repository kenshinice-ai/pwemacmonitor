import Foundation

enum Health: Int, Comparable {
    case calm = 0, warm = 1, hot = 2
    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
    static func grade(_ v: Double, warm: Double, hot: Double) -> Health { v >= hot ? .hot : v >= warm ? .warm : .calm }
    /// Band as a word. "warm" and "hot" are the metaphor the whole instrument runs on, so they
    /// stay temperature-shaped in every language even on the channels that count bytes or watts.
    var word: String {
        switch self {
        case .calm: return L("health.calm", "calm")
        case .warm: return L("health.warm", "warm")
        case .hot:  return L("health.hot", "hot")
        }
    }

    /// Warm begins at this fraction of the way to trouble, for every channel alike.
    static let warmMark = 0.72

    /// Re-express a reading as the distance it has travelled toward its own hot threshold:
    /// 0 at rest, exactly `warmMark` at the warm threshold, exactly 1 at the hot one, and past
    /// 1 beyond it. Putting every channel on one scale is what lets a feather's length and its
    /// colour come from a single number, so the two can never disagree — and it means the same
    /// fraction of a feather means the same thing whether the channel counts watts or degrees.
    static func strain(_ v: Double, warm: Double, hot: Double) -> Double {
        guard hot > warm, warm > 0, v > 0 else { return 0 }
        if v < warm { return warmMark * v / warm }
        return warmMark + (1 - warmMark) * (v - warm) / (hot - warm)
    }
}

/// macOS's own verdict on thermal pressure — the only authoritative signal this app has.
///
/// Everything else it grades is a *magnitude* measured against a threshold we picked: watts
/// against an envelope, die temperature against a number. Those say how hard the machine is
/// working, which is not the same as saying something is wrong. This one is computed by the OS
/// from the actual thermal budget, and `serious` is defined as performance already being reduced.
/// Free to read, no entitlement, and it posts `ProcessInfo.thermalStateDidChangeNotification`.
enum ThermalState: Int, Comparable, CaseIterable {
    case nominal = 0, fair, serious, critical
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    init(_ s: ProcessInfo.ThermalState) {
        switch s {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    /// Apple's own words for these are one adjective each, which tells a reader nothing about
    /// what it means for them. Say the consequence instead.
    var word: String {
        switch self {
        case .nominal:  return L("thermal.nominal", "Nominal")
        case .fair:     return L("thermal.fair", "Slightly elevated")
        case .serious:  return L("thermal.serious", "Performance reduced")
        case .critical: return L("thermal.critical", "Cooling down")
        }
    }

    /// `fair` is documented as "thermals slightly elevated, fans may become audible" — that is a
    /// machine working, not a machine in trouble, so it takes no colour. Colour in this interface
    /// means look at me.
    var health: Health {
        switch self {
        case .nominal, .fair: return .calm
        case .serious: return .warm
        case .critical: return .hot
        }
    }

    /// Contribution to a channel's strain. Only the two states that mean something contribute.
    var strain: Double {
        switch self {
        case .nominal, .fair: return 0
        case .serious: return Health.warmMark
        case .critical: return 1
        }
    }
}

enum PowerSource: String {
    /// The Energy Model's CPU counter, advancing every sample — exact, and what macOS 26 gives.
    case energyModel = "energy_model"
    /// The PMP per-cluster power histograms — what macOS 27 still updates every second.
    case clusterHistogram = "pmp_histogram"
    /// CLPC's own CPU counter — for a Mac that has no cluster histograms (M3, M5 Max), and only
    /// once a witness has said the table fits. See `CLPC` and `Sampler.gpuAgrees`.
    case clpc
    case none
}

/// What this Mac physically has. Decided once, from the hardware, and never from a sample.
///
/// A desktop has no battery and an Air has no fans, for the life of the machine — a card for
/// either would show one line of "none" forever. But the panel's first rule is that it never
/// changes size between refreshes, so the decision cannot hang on a reading: one failed battery
/// read would reflow the grid mid-glance. The IORegistry and the SMC key list say what is
/// fitted, which is the question being asked. Capabilities, not model identifiers, so a machine
/// released next year needs no table entry.
struct Hardware: Equatable {
    var hasBattery: Bool
    var hasFans: Bool

    static let laptop = Hardware(hasBattery: true, hasFans: true)

    func has(_ card: PanelCard) -> Bool {
        switch card {
        case .battery: return hasBattery
        case .fans: return hasFans
        default: return true
        }
    }
}

/// The switchable cards, in reading order. The grid pairs whichever of the first six are present
/// and shown, so hiding one card — by hardware or by choice — reflows the rest instead of leaving
/// a padded hole beside its partner.
enum PanelCard: String, CaseIterable {
    case thermals, memory, fans, battery, storage, network, processes

    static let grid: [PanelCard] = [.thermals, .memory, .fans, .battery, .storage, .network]

    var title: String {
        switch self {
        case .thermals:  return L("section.thermals", "Thermals")
        case .memory:    return L("section.memory", "Memory")
        case .fans:      return L("section.fans", "Fans")
        case .battery:   return L("section.battery", "Battery")
        case .storage:   return L("section.storage", "Storage")
        case .network:   return L("section.network", "Network")
        case .processes: return L("section.processes", "Top Processes")
        }
    }
}

/// The five channels the wing mark reports, innermost feather first. Fixed at five: the mark has
/// five feathers and the identity standard forbids changing that count, so a sixth channel would
/// have nowhere to go. Battery therefore rides with power rather than claiming a feather.
enum Channel: Int, CaseIterable {
    case memory = 0, ssd, power, gpu, cpu
    /// Never translated: these five key the five feathers, and `docs/wing-states.md` defines the
    /// channels by these exact strings.
    var label: String { ["MEM", "SSD", "PWR", "GPU", "CPU"][rawValue] }
    /// The two channels macOS's thermal state lifts by itself. Under "performance reduced" these
    /// are already explained and are named again only if they are worse; memory, storage and
    /// power are separate conditions and are always named.
    var isDie: Bool { self == .cpu || self == .gpu }
    var name: String {
        switch self {
        case .memory: return L("channel.memory", "Memory")
        case .ssd:    return L("channel.storage", "Storage")
        case .power:  return L("channel.power", "Power")
        case .gpu:    return "GPU"
        case .cpu:    return "CPU"
        }
    }
}

/// One channel's reading, expressed twice: `band` is which tier it has entered, `fill` how far
/// through the tier it is. Both are derived from the same strain value, so a feather can never
/// be short and red or long and quiet.
struct ChannelHealth {
    let channel: Channel
    let band: Health
    let fill: Double        // 0…1, clamped for drawing; the band already records any overshoot
}

/// The four readings graded against a threshold we chose, each of which can hover on it.
enum Magnitude: CaseIterable { case cpuTemp, cpuTempMax, gpuTemp, power }

/// How long the system has been short of memory: from the moment its pressure level left normal
/// to now. One spell, whatever happens inside it — warning rising to critical does not start the
/// count again, because the question is how long this Mac has been struggling, and the word
/// beside the figure already says how badly.
///
/// The kernel keeps its own time-at-level (xnu `vm_pressure_response`) and does not publish it,
/// so this is counted here, to the nearest sample.
struct PressureClock {
    /// System uptime at which the level left normal; nil while it is normal.
    private(set) var since: TimeInterval?
    /// False when the first thing this process saw was pressure already on. The spell began before
    /// we were looking, so its length is a floor and is printed with a plus.
    private(set) var startKnown = true
    /// The spell before this one: how long it lasted, and the uptime at which it ended.
    private(set) var lastSeconds: TimeInterval?, lastEnded: TimeInterval?
    /// Whether that spell's start was seen; if not, its length is a floor too.
    private(set) var lastStartKnown = true
    private var seenAny = false
    private(set) var now: TimeInterval = 0

    /// An unreadable level changes nothing: not knowing is not the pressure ending.
    mutating func update(_ level: MemoryPressure?, now: TimeInterval) {
        self.now = now
        guard let level else { return }
        if level == .normal {
            if let s = since { lastSeconds = now - s; lastEnded = now; lastStartKnown = startKnown }
            since = nil; startKnown = true
        } else if since == nil {
            since = now; startKnown = seenAny
        }
        seenAny = true
    }

    var seconds: TimeInterval? { since.map { max(0, now - $0) } }

    /// "45s", "12m", "1h 12m" — and "12m+" when the start was not seen.
    var text: String? {
        guard let t = seconds else { return nil }
        let body = PressureClock.format(t)
        return startKnown ? body : String(format: L("fmt.atLeast", "%@+"), body)
    }
    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return String(format: L("fmt.dur.s", "%ds"), s) }
        if s < 3600 { return String(format: L("fmt.dur.m", "%dm"), s / 60) }
        return String(format: L("value.hm", "%1$dh %2$dm"), s / 3600, (s % 3600) / 60)
    }
}

struct CoreMetric: Identifiable {
    let id: String          // IOReport channel name
    let isP: Bool
    var die: Int = 0, index: Int = 0
    var freqMHz: Int, scaled: Double, active: Double
    /// Human label for a tooltip: "3" on a single-die chip, "die 1 · 3" on an Ultra.
    var core_label: String { die > 0 ? "die \(die) · \(index)" : "\(index)" }
}

struct FanMetric: Identifiable {
    let id: String
    var rpm: Int, maxRPM: Int?
    var ratio: Double { maxRPM.map { zeroDiv(Double(rpm), Double($0)) } ?? 0 }
}

struct Sensor: Identifiable {
    /// Unique per snapshot: IOHID reports several services under the same product name
    /// (six "gas gauge battery" sensors on a MacBook Pro), and duplicate ids break SwiftUI lists.
    let id: String
    let name: String, value: Double, source: String
}

struct Snapshot {
    var time = Date()
    var interval = 2.0

    // CPU
    var cpuUsage = 0.0, cpuActive = 0.0          // 0–1 (frequency-scaled, and raw active)
    var ecpuFreq = 0, pcpuFreq = 0, ecpuUsage = 0.0, pcpuUsage = 0.0
    var cores: [CoreMetric] = []
    var loadAvg: (Double, Double, Double) = (0, 0, 0)
    // GPU
    var gpuUsage = 0.0, gpuActive = 0.0, gpuFreq = 0
    // Power (W)
    var cpuPower = 0.0, gpuPower = 0.0, anePower = 0.0, ramPower = 0.0, sysPower = 0.0
    var allPower: Double { cpuPower + gpuPower + anePower }
    /// The four rails the silicon card draws, summed. `allPower` omits DRAM and is part of the
    /// `--json` surface, so it is left alone; but the figure printed beside the rail legend has to
    /// equal the four bars underneath it or the card contradicts itself in front of the reader.
    var railPower: Double { cpuPower + gpuPower + anePower + ramPower }
    /// Where `cpuPower` came from this sample, if anywhere. See `Sampler.energyModelLive`.
    var cpuPowerSource = PowerSource.none
    /// A rail that is not being measured this sample is left out of the panel and printed as a
    /// dash, never as a zero. The two are separate since 1.7.0: on macOS 27 the Neural Engine
    /// comes back through `CLPC` and DRAM does not.
    var aneReadable = false, ramReadable = false
    /// Where `anePower` came from: `energy_model`, `clpc`, or `none`.
    var aneSource = "none"
    var cpuPowerReadable: Bool { cpuPowerSource != .none }
    /// False when the SMC gave no system figure and `sysPower` is only the rails added up.
    var sysPowerMeasured = false
    /// False until one interval of the hardware counters has been measured. Before that every
    /// figure here is a default, and "all five channels calm" would be a statement about nothing.
    var primed = false
    // Thermals (°C)
    var cpuTemp = 0.0, cpuTempMax = 0.0, gpuTemp = 0.0, ssdTemp = 0.0, batteryTemp = 0.0
    var sensors: [Sensor] = []
    var fans: [FanMetric] = []
    // Memory / Disk / Net / Battery
    var memory = MemoryStats()
    /// Bytes a second read back from swap and written out to it.
    var swapInPerSec = 0.0, swapOutPerSec = 0.0
    /// How long the system has been short of memory. See `PressureClock`.
    var pressure = PressureClock()
    var disk = DiskStats()
    var diskReadPerSec = 0.0, diskWritePerSec = 0.0
    var netInPerSec = 0.0, netOutPerSec = 0.0
    var network = NetworkStats()
    var battery = BatteryStats()
    var processes: [ProcessStat] = []
    /// The list is ordered by memory while the system is short of it: the question has changed
    /// from "who is busy" to "who is holding it".
    var processesByMemory = false
    var uptime: TimeInterval = 0
    // What the OS says, as opposed to what we measure
    var thermal = ThermalState.nominal
    var lowPowerMode = false
    /// Magnitudes that reached warm and have not yet fallen clear of it. See `Snapshot.holds`.
    var held: Set<Magnitude> = []

    // MARK: health grading
    //
    // Two kinds of signal live here and they are no longer drawn the same way.
    //
    // A **verdict** comes from the OS or a published limit and means something is wrong: macOS's
    // `thermalState`, memory pressure, the battery outside Apple's operating range, the SSD past
    // its rated temperature. Only these may reach `.hot`.
    //
    // A **magnitude** is a number graded against a threshold we chose — die temperature, watts.
    // These cap at `.warm`. Measured 2026-09-09 on an M4 Max, which is why:
    //
    //   ordinary use (20–36 % CPU)   67–82 °C avg, 76–90 °C peak, 33–42 W   thermalState nominal
    //   sustained full load          96–110 °C avg, 105–117 °C peak, ≤143 W thermalState fair
    //
    // The old thresholds called 92 °C hot, so every one of 147 load samples graded hot while macOS
    // never once said worse than `fair` — and ordinary browsing peaked at 89.5 °C, 2.5 °C short of
    // a red panel. Raising the number would only move the guess. Capping magnitudes at warm makes a
    // mis-calibrated threshold cosmetic — amber arrives early or late — instead of a false alarm.
    static let tempWarm = 95.0, tempFill = 110.0
    /// A magnitude that has turned warm stays warm until it is clearly below the line again:
    /// 3 °C for a die, five points of the envelope for power.
    ///
    /// Without that, a reading sitting on its threshold changes band with every sample. Recorded
    /// 2026-10-09 under a sustained load that held the hottest core at 94–96 °C: the verdict line
    /// went from "CPU warm" to "All five channels calm" and back nine times in forty seconds, and
    /// the wing in the menu bar blinked with it. The band is a statement about the machine, and
    /// the machine had not changed.
    ///
    /// Only the four magnitudes. A verdict — memory pressure, the battery's range, the SSD's
    /// rating, macOS's thermal state — is somebody else's line, and is reported where they drew it.
    static let tempRelease = 3.0, powerWarm = 0.85, powerRelease = 0.80
    static func holds(_ was: Bool, _ v: Double, warm: Double, release: Double) -> Bool {
        v >= warm || (was && v >= release)
    }
    /// What `held` should be for these readings, given what it was a sample ago.
    func holding(after previous: Set<Magnitude>, chipClass: String) -> Set<Magnitude> {
        let envelope = Snapshot.powerEnvelope(chipClass)
        return Set(Magnitude.allCases.filter { m in
            switch m {
            case .cpuTemp:    return Snapshot.holds(previous.contains(m), cpuTemp, warm: Snapshot.tempWarm, release: Snapshot.tempWarm - Snapshot.tempRelease)
            case .cpuTempMax: return Snapshot.holds(previous.contains(m), cpuTempMax, warm: Snapshot.tempWarm, release: Snapshot.tempWarm - Snapshot.tempRelease)
            case .gpuTemp:    return Snapshot.holds(previous.contains(m), gpuTemp, warm: Snapshot.tempWarm, release: Snapshot.tempWarm - Snapshot.tempRelease)
            case .power:      return Snapshot.holds(previous.contains(m), sysPower, warm: envelope * Snapshot.powerWarm, release: envelope * Snapshot.powerRelease)
            }
        })
    }
    /// A magnitude's band: its own reading, or warm while it is being held, and never hot.
    private func magnitude(_ m: Magnitude, _ v: Double, warm: Double, hot: Double) -> Health {
        min(.warm, max(Health.grade(v, warm: warm, hot: hot), held.contains(m) ? .warm : .calm))
    }
    /// The same thing as a strain: a held magnitude stands on the warm mark until it lets go.
    private func strain(_ m: Magnitude, _ v: Double, warm: Double, hot: Double) -> Double {
        min(Health.warmMark + 0.14, max(Health.strain(v, warm: warm, hot: hot), held.contains(m) ? Health.warmMark : 0))
    }
    var cpuTempHealth: Health { magnitude(.cpuTemp, cpuTemp, warm: Snapshot.tempWarm, hot: Snapshot.tempFill) }
    /// The hottest core is what actually drives throttling, so it grades separately from the average.
    var cpuTempMaxHealth: Health { magnitude(.cpuTempMax, cpuTempMax, warm: Snapshot.tempWarm, hot: Snapshot.tempFill) }
    var gpuTempHealth: Health { magnitude(.gpuTemp, gpuTemp, warm: Snapshot.tempWarm, hot: Snapshot.tempFill) }
    var ssdTempHealth: Health { ssdTemp == 0 ? .calm : Health.grade(ssdTemp, warm: 55, hot: 68) }
    var cpuLoadHealth: Health { Health.grade(cpuUsage, warm: 0.55, hot: 0.85) }
    var gpuLoadHealth: Health { Health.grade(gpuUsage, warm: 0.55, hot: 0.85) }
    /// macOS's verdict and nothing else. How full memory is does not colour anything: see
    /// `MemoryPressure`. An unreadable level is calm — unknown is not a fault.
    var memoryHealth: Health { memory.level?.health ?? .calm }
    /// The verdict line's words for memory: the system's level and how long it has held. Nil
    /// while the level is normal or unknown.
    var memoryVerdict: String? {
        guard let level = memory.level, level != .normal else { return nil }
        let line = level == .critical ? L("verdict.memory.critical", "Memory pressure critical")
                                      : L("verdict.memory.warning", "Memory pressure warning")
        return pressure.text.map { line + L("verdict.joiner", " · ") + $0 } ?? line
    }
    var diskHealth: Health { Health.grade(disk.usedRatio, warm: 0.85, hot: 0.95) }
    var fanHealth: Health { fans.map { Health.grade($0.ratio, warm: 0.45, hot: 0.8) }.max() ?? .calm }
    var batteryHealth: Health {
        guard battery.present else { return .calm }
        if battery.temperature > 42 || (battery.percent < 10 && !battery.externalPower) { return .hot }
        if battery.temperature > 38 || (battery.percent < 20 && !battery.externalPower) { return .warm }
        return .calm
    }
    /// The system rail's rough ceiling, per chip class. The old table read like package-power
    /// figures while `sysPower` is SMC `PSTR` — the whole machine, display included — so it was
    /// low by a wide margin: an M4 Max measured 142.8 W against a coded 80. Max is the measured
    /// one; the others are that correction applied proportionally and are **unverified**. Being
    /// wrong here is now cosmetic, because power can no longer reach `.hot`.
    static func powerEnvelope(_ chipClass: String) -> Double {
        ["Ultra": 210, "Max": 140, "Pro": 79][chipClass] ?? 38
    }
    /// Never `.hot`. A chip drawing its full envelope is doing what it was built to do — the same
    /// reason `busy()` caps CPU and GPU load in the panel. Warm at 85 % says "near the ceiling",
    /// which is worth seeing; coral would say "something is wrong", which it is not.
    func powerHealth(chipClass: String) -> Health {
        let envelope = Snapshot.powerEnvelope(chipClass)
        return magnitude(.power, sysPower, warm: envelope * Snapshot.powerWarm, hot: envelope)
    }
    func overall(chipClass: String) -> Health {
        channels(chipClass: chipClass).map(\.band).max() ?? .calm
    }

    /// Strain per channel, innermost feather first. Every band shown anywhere in the interface
    /// comes from here — including `overall` — so the mark, the legend and the cards cannot
    /// drift apart. Thresholds are the same ones the individual `*Health` properties use, with
    /// `thermal` folded into the two die channels on top.
    func channels(chipClass: String) -> [ChannelHealth] {
        Channel.allCases.map { c in
            let v: Double
            switch c {
            case .memory:
                // The level places the feather: the warm mark at warning, its tip at critical.
                // How full memory is only says how long the line is while everything is normal,
                // and stops short of the warm mark — a Mac at 95 % used with the system content is
                // a calm Mac, and that is the rule this replaces (`MemoryPressure`).
                let fullness = min(Health.warmMark - 0.02, Health.warmMark * memory.usedRatio)
                switch memory.level {
                case .critical: v = 1
                case .warning:  v = Health.warmMark
                default:        v = max(0, fullness)
                }
            case .ssd:
                v = ssdTemp == 0 ? 0 : Health.strain(ssdTemp, warm: 55, hot: 68)
            case .power:
                // Watts are a magnitude and cap at warm; the battery conditions below are real
                // limits — Apple's operating range and a charge that is about to run out — and
                // keep their path to hot.
                let envelope = Snapshot.powerEnvelope(chipClass)
                var s = strain(.power, sysPower, warm: envelope * Snapshot.powerWarm, hot: envelope)
                if battery.present {
                    // `.nextUp` because `strain` grades inclusively and the rule this replaces
                    // was strictly greater. Cheaper to be exact than to argue about whether a
                    // sensor can report 38.000000.
                    s = max(s, Health.strain(battery.temperature, warm: 38.0.nextUp, hot: 42.0.nextUp))
                    if !battery.externalPower {
                        // Likewise integer percent: `< 20` / `< 10`.
                        s = max(s, Health.strain(100 - Double(battery.percent), warm: 81, hot: 91))
                    }
                }
                v = s
            // Die temperature fills the feather; macOS decides whether it is a problem. Both
            // feathers take the thermal state because it is one condition on one die — and it is
            // the only signal here that measured out as tracking reality (see `tempWarm`).
            case .gpu:
                v = max(strain(.gpuTemp, gpuTemp, warm: Snapshot.tempWarm, hot: Snapshot.tempFill), thermal.strain)
            case .cpu:
                v = max(strain(.cpuTempMax, cpuTempMax, warm: Snapshot.tempWarm, hot: Snapshot.tempFill), thermal.strain)
            }
            return ChannelHealth(channel: c,
                                 band: Health.grade(v, warm: Health.warmMark, hot: 1),
                                 fill: min(1, v))
        }
    }
}

extension Array where Element == ChannelHealth {
    /// Channels that have left calm, worst first.
    private var notable: [ChannelHealth] {
        filter { $0.band != .calm }.sorted { $0.band > $1.band }
    }

    /// What the wing says, on screen, in one line.
    ///
    /// The mark encodes all five channels as colour and feather length, which is exact and
    /// silent: someone opening the panel for the first time sees five grey bars and no statement
    /// of what they mean. This is that statement, and it is the first thing under the wordmark.
    /// `thermal` and `lowPower` are passed in rather than read from a channel because neither is
    /// one: they are conditions on the whole machine, and both answer the question a reader
    /// actually arrives with — why is this slow — which no per-channel number does.
    ///
    /// `memory` replaces the memory channel's clause when macOS reports pressure. That channel has
    /// no reading of its own to quote: its feather stands on the warm mark because the system said
    /// "warning", so "72 % to its limit" would be our drawing convention read back as a figure.
    /// `primed` is false until the first interval has been measured; nothing is claimed before.
    func headline(thermal: ThermalState = .nominal, lowPower: Bool = false,
                  memory: String? = nil, primed: Bool = true) -> String {
        guard primed else { return L("verdict.reading", "Reading…") }
        var parts: [String] = []
        // macOS leads when it has something to say. `serious` is defined as performance already
        // being reduced, which outranks any reading we took ourselves.
        if thermal >= .serious { parts.append(thermal.word) }
        // Only channels worse than the state already explains. The thermal state lifts the two die
        // channels itself, so without this the line reads "Performance reduced · GPU warm · 72% to
        // its limit" — and that 72 % is the state's own contribution, not the GPU's temperature.
        // Saying it twice makes one condition look like two.
        let listed = thermal >= .serious ? notable.filter { !$0.channel.isDie || $0.band > thermal.health } : notable
        if let worst = listed.first {
            if worst.channel == .memory, let memory {
                parts.append(memory)
            } else {
                parts.append(String(format: L("verdict.one", "%1$@ %2$@ · %3$d%% to its limit"),
                                    worst.channel.name, worst.band.word, Int((worst.fill * 100).rounded())))
            }
            if listed.count > 1 {
                parts[parts.count - 1] += String(format: L("verdict.more", " · +%d more"), listed.count - 1)
            }
        }
        if parts.isEmpty { parts.append(L("verdict.calm", "All five channels calm")) }
        // Low Power Mode caps performance on purpose. A panel that cannot see it leaves the reader
        // hunting for a fault that is a setting.
        if lowPower { parts.append(L("verdict.lowPower", "Low Power Mode")) }
        return parts.joined(separator: L("verdict.joiner", " · "))
    }

    /// The same reading for VoiceOver, at length. Sentence shape is table data rather than string
    /// interpolation — the joiner and the closing clause are entries of their own — because
    /// English punctuation baked into the concatenation produces Chinese that does not parse.
    func spoken(thermal: ThermalState = .nominal, lowPower: Bool = false,
                memory: String? = nil, primed: Bool = true) -> String {
        guard primed else { return L("verdict.reading", "Reading…") }
        // Same two conditions the printed verdict leads with, and for the same reason: a screen
        // reader user asking why the machine is slow needs them before any per-channel figure.
        var lead = ""
        if thermal >= .serious { lead = thermal.word + L("a11y.sentenceEnd", ". ") }
        if lowPower { lead += L("verdict.lowPower", "Low Power Mode") + L("a11y.sentenceEnd", ". ") }
        let listed = thermal >= .serious ? notable.filter { !$0.channel.isDie || $0.band > thermal.health } : notable
        guard !listed.isEmpty else { return lead + L("a11y.allCalm", "All five channels calm.") }
        let list = listed.map { c -> String in
            if c.channel == .memory, let memory { return memory }
            return String(format: L("a11y.channel", "%1$@ %2$@, %3$d percent of the way to its limit"),
                          c.channel.name, c.band.word, Int((c.fill * 100).rounded()))
        }
        return lead + list.joined(separator: L("a11y.joiner", ". ")) + L("a11y.restCalm", ". The rest calm.")
    }
}

/// Orchestrates all sources. Call `sample()` from a background queue every few seconds.
final class Sampler {
    let soc: SocInfo
    /// See `Hardware`. Read in `init` and never again.
    private(set) var hardware = Hardware.laptop
    /// Whether the Energy Model's millijoule counters are advancing *every* sample.
    ///
    /// On macOS 27 they land in batches every three to five minutes: zero, zero, zero, then several
    /// minutes of energy at once. Divided by a two-second interval that batch is a spike of a
    /// hundred watts or more, so "has it ever moved" is not enough — 1.5.0 used exactly that and
    /// would have drawn the spike, then gone back to zero. A running CPU never draws nothing over
    /// an interval, so the counter counts as live only when it moved this sample *and* the last.
    private var cpuEnergyMovedLastSample = false
    /// Histogram ticks per second, learned as the fastest seen. A cluster that is powered down
    /// logs no residency at all, so a histogram's own total understates the interval; the rate is
    /// the clock every histogram shares, and residency missing from it is time spent at 0 W.
    private var histogramTickRate = 0.0
    private var lastANE = 0.0, lastDRAM = 0.0
    /// Whether the CLPC table is the right one for this OS: nil until the witness has spoken,
    /// then true, or false for the rest of the run. See `clpcAgrees`.
    private var clpcTrusted: Bool?
    private var witnessCLPC = 0.0, witnessHistogram = 0.0, witnessTime = 0.0
    private var gpuWitnessCLPC = 0.0, gpuWitnessCounter = 0.0, gpuWitnessTime = 0.0
    /// `PWEMON_NO_HISTOGRAMS=1` makes this Mac read like one that lists no cluster histograms —
    /// an M3, an M5 Max — so the path those chips take can be run on the chip it was written on.
    private let ignoreHistograms = ProcessInfo.processInfo.environment["PWEMON_NO_HISTOGRAMS"] == "1"
    private var pressureClock = PressureClock()
    private var primed = false
    /// `PWEMON_PRESSURE=warning` or `=critical` puts the memory level there for this process, the
    /// way `PWEMON_HARDWARE` puts another Mac's layout on this one. The real level needs root to
    /// move (`memory_pressure -S`); the screenshots and a check of the panel's three states do not.
    /// Everything downstream — the clock, the verdict, the order of the process list — runs as it
    /// would for the real thing.
    private let forcedPressure: MemoryPressure? = {
        switch ProcessInfo.processInfo.environment["PWEMON_PRESSURE"] {
        case "warning": return .warning
        case "critical": return .critical
        default: return nil
        }
    }()
    private var prevSwap: (ins: UInt64, outs: UInt64, at: TimeInterval)?
    private var procOrder = ProcessSampler.Order.cpu
    private let ioreport: IOReport?
    private let smc: SMC?
    private let hid: IOHIDSensors?
    private let procs = ProcessSampler()
    private let net = NetworkSampler()
    /// See `Snapshot.holds`. Carried from one sample to the next; this is the only state a band has.
    private var held: Set<Magnitude> = []
    // Every temperature key the SMC exposes, and the subset that is actually reporting a live die.
    // A full sweep of ~190 keys costs ~40 ms of waiting on the SMC; the live subset is less. Parked
    // clusters report an exact 40.0 °C placeholder, zero, or a sub-ambient value, and can wake
    // later, so the full set is re-classified every ten seconds.
    private var smcCPUKeys: [String] = [], smcGPUKeys: [String] = [], smcFanKeys: [String] = []
    private var liveCPUKeys: [String] = [], liveGPUKeys: [String] = []
    private var lastKeyScan: TimeInterval = -1e9
    /// IOHID services worth reading every sample: SSD and battery, plus die sensors when the SMC
    /// has none (M1 / older macOS).
    private var hotHIDNames: Set<String> = []
    private var prevDisk: (DiskStats, TimeInterval)?
    private var lastProcSample: TimeInterval = 0
    /// Guards the SMC connection and the IOHID client. `sample()` spends most of its wall time
    /// asleep inside IOReport's interval wait, so an on-demand sensor read from another queue only
    /// has to wait for the short thermal section rather than for the whole sampling interval.
    private let sensorLock = NSLock()
    private var cachedProcs: [ProcessStat] = []

    init?() {
        guard let soc = SocInfo.load() else { return nil }
        self.soc = soc
        ioreport = IOReport()
        // What an earlier run witnessed on this same build of macOS still holds; both witnesses
        // go on checking, and either one can take it back.
        if let key = CLPC.tableKey, UserDefaults.standard.string(forKey: CLPC.witnessedDefault) == key { clpcTrusted = true }
        smc = SMC()
        hid = IOHIDSensors()
        if let smc {
            for k in smc.allKeys() where k.count == 4 {
                if k.hasPrefix("F"), k.hasSuffix("Ac") { smcFanKeys.append(k); continue }
                let isCPU = k.hasPrefix("Tp") || k.hasPrefix("Te") || k.hasPrefix("Ts")
                let isGPU = k.hasPrefix("Tg")
                // By type, never by what the key happens to read at this instant. Until 1.6.0 a
                // key reading zero here was dropped for the life of the process, and a cluster
                // that is powered down reads zero: six launches in a row kept 146, 146, 146, 116,
                // 146 and 146 of the same 146 keys, and an earlier one kept 74. Whichever cores
                // were asleep at launch could then get as hot as they liked unseen.
                guard isCPU || isGPU, let v = smc.read(k), v.type == "flt " else { continue }
                if isCPU { smcCPUKeys.append(k) } else { smcGPUKeys.append(k) }
            }
            smcFanKeys = Array(Set(smcFanKeys)).sorted()
        }
        // A laptop's gas gauge is `AppleSmartBattery`; a desktop has no such service at all.
        // `BatteryInstalled` covers the machine whose battery has been removed for service.
        let gauge = ioFirstProperties("AppleSmartBattery")
        hardware = Hardware(hasBattery: gauge.map { ($0["BatteryInstalled"] as? Bool) ?? true } ?? false,
                            hasFans: !smcFanKeys.isEmpty)
        classifyLiveKeys(now: 0)

        if let hid {
            // "Has none" means none that reads, as it always did — the key set is no longer
            // filtered by value, so the question is asked here instead. A Mac whose SMC lists die
            // keys and answers zero on all of them still needs its dies from IOHID.
            func reads(_ keys: [String]) -> Bool {
                keys.contains { k in smc?.readFloat(k).map { $0 > 0 && $0 < 150 } ?? false }
            }
            let needsDieFromHID = !reads(smcCPUKeys) || !reads(smcGPUKeys)
            for name in hid.sensorNames {
                let upper = name.uppercased(), lower = name.lowercased()
                if upper.contains("NAND") || lower.contains("battery") || lower.contains("gas gauge") {
                    hotHIDNames.insert(name)
                } else if needsDieFromHID,
                          name.hasPrefix("pACC MTR") || name.hasPrefix("eACC MTR") || name.hasPrefix("GPU MTR") {
                    hotHIDNames.insert(name)
                }
            }
        }
    }

    /// Re-test every SMC temperature key and keep the ones reporting a plausible live die value.
    private func classifyLiveKeys(now: TimeInterval) {
        guard let smc else { return }
        lastKeyScan = now
        liveCPUKeys = smcCPUKeys.filter { key in
            guard let v = smc.readFloat(key) else { return false }
            return v >= 20 && v != 40.0 && v < 150
        }
        liveGPUKeys = smcGPUKeys.filter { key in
            guard let v = smc.readFloat(key) else { return false }
            return v >= 20 && v < 150
        }
        // If everything looked parked, fall back to the full set rather than reporting nothing.
        if liveCPUKeys.isEmpty { liveCPUKeys = smcCPUKeys }
        if liveGPUKeys.isEmpty { liveGPUKeys = smcGPUKeys }
    }

    var sourcesDescription: String {
        let smcPart = smc != nil
            ? "on(cpu \(liveCPUKeys.count)/\(smcCPUKeys.count), gpu \(liveGPUKeys.count)/\(smcGPUKeys.count), fan \(smcFanKeys.count))"
            : "off"
        return "IOReport:\(ioreport != nil ? "on" : "off") SMC:\(smcPart) IOHID:\(hid != nil ? "on(\(hotHIDNames.count) hot)" : "off")"
    }

    private func calcFreq(_ items: [(String, Int64)], freqs: [UInt32]) -> (Int, Double, Double) {
        guard !freqs.isEmpty, items.count > freqs.count,
              let offset = items.firstIndex(where: { !["IDLE", "DOWN", "OFF"].contains($0.0) }) else { return (0, 0, 0) }
        let usage = items.dropFirst(offset).prefix(freqs.count).reduce(0.0) { $0 + Double($1.1) }
        let total = items.reduce(0.0) { $0 + Double($1.1) }
        var avg = 0.0
        for i in 0..<freqs.count where i + offset < items.count {
            avg += zeroDiv(Double(items[i + offset].1), usage) * Double(freqs[i])
        }
        let active = zeroDiv(usage, total)
        let minF = Double(freqs.first!), maxF = Double(freqs.last!)
        let scaled = zeroDiv(max(avg, minF) * active, maxF)
        return (Int(avg), scaled, active)
    }

    /// - Parameter allSensors: sweep every SMC key and IOHID service, for the "all sensors" panel.
    ///   That full sweep costs roughly 60 ms more than the live subset the rest of the app needs,
    ///   so it only runs while the panel is actually on screen.
    /// - Parameter detail: someone is reading the panel. The process table is the one source
    ///   nothing but the panel shows; see where it is sampled.
    func sample(interval: Double, allSensors: Bool = false, detail: Bool = true) -> Snapshot {
        var s = Snapshot()
        s.interval = interval
        s.uptime = ProcessInfo.processInfo.systemUptime
        var la = [Double](repeating: 0, count: 3); getloadavg(&la, 3); s.loadAvg = (la[0], la[1], la[2])

        if let ioreport, let sample = ioreport.sampleSincePrevious() {
            var cores: [CoreMetric] = []
            var emCPU = 0.0, emANE = 0.0, emDRAM = 0.0
            var clusterEnergy = 0.0, clusterTicks = 0.0, sawCluster = false
            var clpcCPU: Double?, clpcGPU: Double?, clpcANE: Double?
            primed = true
            for ch in sample.channels {
                switch (ch.group, ch.subgroup) {
                case ("CPU Stats", "CPU Core Performance States"):
                    let isP = ch.name.contains("PCPU")
                    guard isP || ch.name.contains("ECPU") || ch.name.contains("MCPU") else { continue }
                    let (f, sc, ac) = calcFreq(ioreport.residencies(ch.item), freqs: isP ? soc.pcpuFreqs : soc.ecpuFreqs)
                    let key = Self.coreSortKey(ch.name)
                    cores.append(CoreMetric(id: ch.name, isP: isP, die: key.0, index: key.3, freqMHz: f, scaled: sc, active: ac))
                case ("GPU Stats", "GPU Performance States") where ch.name == "GPUPH":
                    let (f, sc, ac) = calcFreq(ioreport.residencies(ch.item), freqs: Array(soc.gpuFreqs.dropFirst()))
                    s.gpuFreq = f; s.gpuUsage = sc; s.gpuActive = ac
                case ("Energy Model", _):
                    let w = ioreport.watts(ch, elapsed: sample.elapsed)
                    if ch.name == "GPU Energy" { s.gpuPower += w }
                    else if ch.name.hasSuffix("CPU Energy") { emCPU += w }
                    else if ch.name.hasPrefix("ANE") { emANE += w }
                    else if ch.name.hasPrefix("DRAM") { emDRAM += w }
                case (CLPC.group, _):
                    let w = ioreport.watts(ch, elapsed: sample.elapsed)
                    if ch.name == CLPC.cpuName { clpcCPU = w } else if ch.name == CLPC.gpuName { clpcGPU = w }
                    else if ch.name == CLPC.aneName { clpcANE = w }
                case ("PMP", "Energy") where IOReport.isClusterHistogram(ch.name) && !ignoreHistograms:
                    let (joulesTicks, ticks) = Self.clusterWatts(ioreport.residencies(ch.item))
                    clusterEnergy += joulesTicks; sawCluster = true
                    clusterTicks = max(clusterTicks, ticks)
                default: break
                }
            }
            // The Energy Model when it is live and believable; the cluster histograms otherwise.
            let live = emCPU > 0 && cpuEnergyMovedLastSample
            cpuEnergyMovedLastSample = emCPU > 0
            histogramTickRate = max(histogramTickRate, clusterTicks / sample.elapsed)
            let histogram = sawCluster && histogramTickRate > 0
                ? clusterEnergy / (histogramTickRate * sample.elapsed) : nil as Double?
            // The witness. CLPC's CPU counter and the histograms measure the same clusters by two
            // routes, and on a table that fits this OS their 30-second means sit within 0.4 W of
            // each other. A table that does not fit reads some other counter, and they part. So
            // the ANE figure — which has no second route to check it against — is shown only while
            // the CPU pair agrees, and once they have disagreed, not again until the app restarts.
            // A counter that ran backwards or jumped — a reset on wake — is not a reading. No Mac's
            // Neural Engine draws fifty watts; neither figure is used outside what is possible.
            if let c = clpcCPU, !(0...500).contains(c) { clpcCPU = nil }
            if let a = clpcANE, !(0...50).contains(a) { clpcANE = nil }
            if let c = clpcCPU, let h = histogram {
                witnessCLPC += c * sample.elapsed; witnessHistogram += h * sample.elapsed; witnessTime += sample.elapsed
                if witnessTime >= Self.witnessWindow {
                    judge(Self.clpcAgrees(clpc: witnessCLPC / witnessTime, histogram: witnessHistogram / witnessTime))
                    witnessCLPC = 0; witnessHistogram = 0; witnessTime = 0
                }
            }
            // The second witness, for a Mac with no histograms: the GPU pair. See `gpuAgrees`.
            // Only there — where the histograms exist they answer in thirty seconds whatever the
            // GPU is doing, and a second judge could only add a way to refuse a table that works.
            if histogram == nil, let g = clpcGPU, (0...500).contains(g) {
                gpuWitnessCLPC += g * sample.elapsed; gpuWitnessCounter += s.gpuPower * sample.elapsed; gpuWitnessTime += sample.elapsed
                if gpuWitnessTime >= Self.witnessWindow {
                    let counter = gpuWitnessCounter / gpuWitnessTime
                    // A GPU at rest says nothing: every counter there is reads about zero beside it.
                    if counter >= Self.gpuWitnessFloor, clpcCPU.map({ $0 > 0.1 }) ?? false {
                        judge(Self.gpuAgrees(clpc: gpuWitnessCLPC / gpuWitnessTime, counter: counter))
                    }
                    gpuWitnessCLPC = 0; gpuWitnessCounter = 0; gpuWitnessTime = 0
                }
            }
            let (cpu, source) = Self.cpuPower(counter: emCPU, counterLive: live, histogram: histogram,
                                              clpc: clpcTrusted == true ? clpcCPU : nil)
            s.cpuPower = cpu; s.cpuPowerSource = source
            if live {
                // A sample whose CPU counter was rejected as carrying a batch carries the same
                // batch on ANE and DRAM; hold the last good figures for that one sample rather than
                // print the spike, or drop the two rails and have the legend flicker.
                if source == .energyModel { lastANE = emANE; lastDRAM = emDRAM }
                s.anePower = lastANE; s.ramPower = lastDRAM
                s.aneReadable = true; s.ramReadable = true; s.aneSource = "energy_model"
            }
            if !live, clpcANE != nil || clpcCPU != nil {
                if clpcTrusted == true, let a = clpcANE {
                    s.anePower = a; s.aneReadable = true; s.aneSource = "clpc"
                } else {
                    // Said in the diagnostics, so a one-shot `--probe` does not read as "no source".
                    s.aneSource = clpcTrusted == false ? "clpc_refused" : "clpc_pending"
                }
            }
            cores.sort { Self.coreSortKey($0.id) < Self.coreSortKey($1.id) }
            s.cores = cores
            let e = cores.filter { !$0.isP }, p = cores.filter { $0.isP }
            let eCount = Double(max(e.count, soc.ecpuCores)), pCount = Double(max(p.count, soc.pcpuCores))
            s.ecpuUsage = zeroDiv(e.reduce(0) { $0 + $1.scaled }, eCount)
            s.pcpuUsage = zeroDiv(p.reduce(0) { $0 + $1.scaled }, pCount)
            s.cpuUsage = zeroDiv(cores.reduce(0) { $0 + $1.scaled }, eCount + pCount)
            s.cpuActive = zeroDiv(cores.reduce(0) { $0 + $1.active }, eCount + pCount)
            s.ecpuFreq = max(Int(zeroDiv(e.reduce(0) { $0 + Double($1.freqMHz) }, Double(e.count))), Int(soc.ecpuFreqs.first ?? 0))
            s.pcpuFreq = max(Int(zeroDiv(p.reduce(0) { $0 + Double($1.freqMHz) }, Double(p.count))), Int(soc.pcpuFreqs.first ?? 0))
        }

        if ioreport == nil { primed = true }        // nothing to wait for: say what the other sources say
        // Once and for all. A later sample that fails to produce a delta is a missed reading, not
        // a return to knowing nothing, and must not take a live verdict off the screen.
        s.primed = primed

        // Thermals: SMC (macOS 14+) preferred for CPU/GPU, IOHID for everything incl. NAND/battery.
        // A power-gated GPU or CPU cluster leaves its die sensors reporting near-zero garbage
        // (observed: Tg keys at 1.6 °C while the CPU sat at 47 °C), so die averages take a floor:
        // no silicon in a running Mac is below room temperature.
        let dieFloor = 20.0
        sensorLock.lock()
        var sensors: [Sensor] = []
        var cpuT: [Double] = [], gpuT: [Double] = [], ssdT: [Double] = []
        if allSensors { sensors.reserveCapacity(smcCPUKeys.count + smcGPUKeys.count + 32) }
        // A cluster that was parked at startup can wake up later, so re-classify now and then.
        if s.uptime - lastKeyScan > 10 { classifyLiveKeys(now: s.uptime) }
        let cpuKeys = allSensors ? smcCPUKeys : liveCPUKeys
        let gpuKeys = allSensors ? smcGPUKeys : liveGPUKeys
        if let smc {
                for k in cpuKeys {
                guard let v = smc.readFloat(k), v > 0, v < 150 else { continue }
                if allSensors { sensors.append(Sensor(id: "smc.\(k)", name: k, value: Double(v), source: "SMC")) }
                // Apple pads the Tp* table with an exact 40.0 °C placeholder on unused sensors.
                if Double(v) >= dieFloor, v != 40.0 { cpuT.append(Double(v)) }
            }
            for k in gpuKeys {
                guard let v = smc.readFloat(k), v > 0, v < 150 else { continue }
                if allSensors { sensors.append(Sensor(id: "smc.\(k)", name: k, value: Double(v), source: "SMC")) }
                if Double(v) >= dieFloor { gpuT.append(Double(v)) }
            }
            if let p = smc.readFloat("PSTR"), p > 0 { s.sysPower = Double(p); s.sysPowerMeasured = true }
            for (i, k) in smcFanKeys.enumerated() {
                guard let v = smc.read(k), let rpm = SMC.numeric(v), rpm >= 0, rpm < 100_000 else { continue }
                var mx: Int? = nil
                if let mv = smc.read(String(k.dropLast(2)) + "Mx"), let m = SMC.numeric(mv), m > 0 { mx = Int(m) }
                s.fans.append(FanMetric(id: "Fan \(i + 1)", rpm: Int(rpm), maxRPM: mx))
            }
        }
        if let hid {
            var hidCPU: [Double] = [], hidGPU: [Double] = []
            for (name, t) in hid.temperatures(only: allSensors ? nil : hotHIDNames) {
                if allSensors { sensors.append(Sensor(id: "hid.\(name).\(sensors.count)", name: name, value: t, source: "HID")) }
                if name.hasPrefix("pACC MTR") || name.hasPrefix("eACC MTR") { if t >= dieFloor { hidCPU.append(t) } }
                else if name.hasPrefix("GPU MTR") { if t >= dieFloor { hidGPU.append(t) } }
                else if name.uppercased().contains("NAND") { ssdT.append(t) }
                else if name.lowercased().contains("battery") || name.lowercased().contains("gas gauge") { s.batteryTemp = max(s.batteryTemp, t) }
            }
            if cpuT.isEmpty { cpuT = hidCPU }
            if gpuT.isEmpty { gpuT = hidGPU }
        }
        // SMC exposes dozens of Tp*/Te*/Tg* keys, many of them on parked clusters reading far below the
        // active die. Average only sensors within 15 °C of the hottest one, and report that max separately.
        sensorLock.unlock()

        s.cpuTempMax = cpuT.max() ?? 0
        s.cpuTemp = Self.dieAverage(cpuT)
        s.gpuTemp = Self.dieAverage(gpuT)
        s.ssdTemp = ssdT.max() ?? 0
        s.sensors = sensors.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        // Never less than the rails it contains: the SMC figure lags a burst by a sample, and a
        // system total below its own parts reads as a fault. `sysPowerMeasured` says whether the
        // SMC answered at all — when it did not, this is the rails and nothing more.
        s.sysPower = max(s.sysPower, s.allPower)

        s.thermal = ThermalState(ProcessInfo.processInfo.thermalState)
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        held = s.holding(after: held, chipClass: soc.chipClass)
        s.held = held

        s.memory = MemoryStats.read()
        if let forcedPressure { s.memory.level = forcedPressure }
        if let p = prevSwap, s.uptime > p.at {
            let page = Double(vm_kernel_page_size), dt = s.uptime - p.at
            // A counter that went backwards is a counter that was reset; that is not traffic.
            if s.memory.swapIns >= p.ins { s.swapInPerSec = Double(s.memory.swapIns - p.ins) * page / dt }
            if s.memory.swapOuts >= p.outs { s.swapOutPerSec = Double(s.memory.swapOuts - p.outs) * page / dt }
        }
        // A failed read leaves the counters at zero; kept as a baseline, the next good read would
        // be differenced against nothing and print gigabytes a second.
        if s.memory.total > 0, s.memory.used > 0 { prevSwap = (s.memory.swapIns, s.memory.swapOuts, s.uptime) }
        pressureClock.update(s.memory.level, now: s.uptime)
        s.pressure = pressureClock
        s.battery = BatteryStats.read()
        if s.batteryTemp == 0 { s.batteryTemp = s.battery.temperature }
        // And the other way. macOS 27 no longer publishes `Temperature` on the gas gauge's
        // registry entry at all, so the figure the battery verdict grades — outside 38 or 42 °C —
        // read zero there and could never fire. The IOHID sensor above is the same cell.
        if s.battery.temperature == 0 { s.battery.temperature = s.batteryTemp }

        let disk = DiskStats.read()
        if let (pd, pt) = prevDisk, s.uptime > pt {
            let dt = s.uptime - pt
            s.diskReadPerSec = Double(disk.readBytes &- pd.readBytes) / dt
            s.diskWritePerSec = Double(disk.writeBytes &- pd.writeBytes) / dt
        }
        prevDisk = (disk, s.uptime); s.disk = disk

        let traffic = net.sample(now: s.uptime)
        s.netInPerSec = traffic.inPerSec; s.netOutPerSec = traffic.outPerSec
        s.network = traffic.stats

        // The process table is read by nobody while the panel is closed, and it is a quarter of
        // what a sample costs: 5.3 ms of CPU for 1,500 processes, measured on the queue and at the
        // spacing the app really uses. (The 1.3 ms this comment used to quote came from a loop
        // on a performance core at full clock.) Closed, it runs every ten seconds — enough to keep
        // a baseline, so the panel opens on a list at most that old and its first live figures are
        // an average over at most that long, rather than on six blank rows.
        // Half a second, not one: at the 1 s setting the timer's leeway can bring two ticks a
        // shade under a second apart, and the table would then skip every other one.
        //
        // The list follows the trouble. While macOS reports memory pressure the question is who
        // is holding the memory, so the table is ordered by footprint; the moment the order
        // changes it is read again rather than left showing the other ranking.
        let order: ProcessSampler.Order = (s.memory.level ?? .normal) == .normal ? .cpu : .memory
        if order != procOrder || s.uptime - lastProcSample >= (detail ? 0.5 : 10) {
            cachedProcs = procs.top(8, by: order)
            lastProcSample = s.uptime; procOrder = order
        }
        s.processes = cachedProcs
        s.processesByMemory = procOrder == .memory
        return s
    }

    /// Every temperature the machine exposes. Costs a full SMC and IOHID sweep (~70 ms), so it is
    /// only called for the "all sensors" panel — once when it opens, then with each sample while it
    /// stays open. Safe to call from any queue; access to the hardware is serialised internally.
    func readAllSensors() -> [Sensor] {
        sensorLock.lock()
        defer { sensorLock.unlock() }
        var sensors: [Sensor] = []
        if let smc {
            for k in smcCPUKeys + smcGPUKeys {
                guard let v = smc.readFloat(k), v > 0, v < 150 else { continue }
                sensors.append(Sensor(id: "smc.\(k)", name: k, value: Double(v), source: "SMC"))
            }
        }
        if let hid {
            for (name, t) in hid.temperatures() {
                sensors.append(Sensor(id: "hid.\(name).\(sensors.count)", name: name, value: t, source: "HID"))
            }
        }
        return sensors.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// Mean of the sensors that are actually reporting the live die: everything within 15 °C of the peak.
    private static func dieAverage(_ temps: [Double]) -> Double {
        guard let peak = temps.max() else { return 0 }
        let live = temps.filter { $0 >= peak - 15 }
        return zeroDiv(live.reduce(0, +), Double(live.count))
    }

    /// Which CPU figure to print.
    ///
    /// A live counter is exact and wins — except when it carries the tail of a batch. On macOS 27 a
    /// counter can advance every second (it does while `powermetrics` runs) and still deliver, in
    /// one of those seconds, energy that accumulated while it was batching: measured 21.69 W in a
    /// run where `powermetrics` said 12.07 and the samples either side read 11. The histogram is
    /// never more than half a band high per cluster and never batches, so a counter reading well
    /// above it — 1.4 times, plus 2 W for the histogram's own coarseness at idle — is a batch, and
    /// the histogram is used for that sample. The same run put the two within 11 % of each other
    /// otherwise, so honest samples sit far inside that margin.
    static func cpuPower(counter: Double, counterLive: Bool, histogram: Double?, clpc: Double? = nil) -> (Double, PowerSource) {
        if counterLive {
            guard let h = histogram, counter > h * 1.4 + 2 else { return (counter, .energyModel) }
            return (h, .clusterHistogram)
        }
        if let h = histogram { return (h, .clusterHistogram) }
        if let c = clpc { return (c, .clpc) }
        return (0, .none)
    }

    /// A witness has spoken. One refusal stands for the rest of the run, whichever witness gave
    /// it; an agreement is remembered for this build of macOS, so the next launch does not wait
    /// minutes for a batch before it shows what this one has already checked.
    private func judge(_ agrees: Bool) {
        guard clpcTrusted != false else { return }
        clpcTrusted = agrees
        guard let key = CLPC.tableKey else { return }
        if agrees { UserDefaults.standard.set(key, forKey: CLPC.witnessedDefault) }
        else { UserDefaults.standard.removeObject(forKey: CLPC.witnessedDefault) }
    }

    /// Seconds of both readings the witness averages before it speaks.
    static let witnessWindow = 30.0

    /// Whether CLPC's CPU counter and the cluster histograms tell the same story over a window.
    ///
    /// Measured 2026-10-12 against each other and against `powermetrics`: 1.62 W and 1.62 W when
    /// quiet, 23.08 W and 22.72 W with every core busy, 2.51 W and 2.29 W under Vision work —
    /// never more than 0.4 W apart on a steady load, and 1.5 W apart (8.36 against 6.82) on one
    /// odd one. A quarter of the reading covers all of them.
    ///
    /// The floor is half a watt, not more, because of the idle Mac: at a watt and a half of CPU a
    /// wider margin would wave through a counter reading nothing at all. And it must read
    /// something — a CPU complex that drew under 0.1 W for thirty seconds is a counter that is
    /// not the CPU's. Quiet pairs measured: 0.72 / 0.92, 0.84 / 1.03, 1.02 / 1.16, 1.47 / 1.51.
    static func clpcAgrees(clpc: Double, histogram: Double) -> Bool {
        clpc > 0.1 && abs(clpc - histogram) <= max(0.5, 0.25 * histogram)
    }

    /// The GPU has to be doing this much, as a 30-second mean, before the GPU pair is judged.
    static let gpuWitnessFloor = 1.5

    /// Whether CLPC's GPU counter and the Energy Model's tell the same story over a window.
    ///
    /// The witness for a Mac with no cluster histograms. `GPU Energy` is the one Energy Model
    /// counter macOS 27 still updates every second, on every chip, so it is a reference the CPU
    /// has lost. If the table's GPU entry reads the GPU, the table fits this OS — the indices
    /// move together between releases — and the CPU and ANE entries beside it are shown. It is
    /// indirect: a right GPU entry beside a wrong CPU one would pass, exactly as a right CPU entry
    /// beside a wrong ANE one passes the histogram witness.
    ///
    /// Measured 2026-10-12 on the M4 Max, every 30-second window of two runs in which the GPU
    /// averaged 1.5 W or more: 20.18 / 20.17, 5.17 / 5.07, 6.25 / 5.81, 22.03 / 21.70 — never more
    /// than 0.44 W apart. Below the floor CLPC's counter carries an unexplained half watt
    /// (docs/power-rails.md), and a GPU at rest cannot tell one idle counter from another, so
    /// those windows are not judged at all.
    static func gpuAgrees(clpc: Double, counter: Double) -> Bool {
        counter >= gpuWitnessFloor && abs(clpc - counter) <= max(0.75, 0.25 * counter)
    }

    /// A PMP cluster histogram, reduced to watt-ticks and ticks. Each state is a power band named
    /// by its upper edge — " 0.250W", "   2W" — so a band's value is the midpoint between its edge
    /// and the one below. Calibrated on the GPU histogram against the GPU's still-working energy
    /// counter: 46.30 W against 46.52 under load. At idle the midpoint of the lowest band dominates
    /// and reads high — half a band, so up to 1 W on a P-cluster — which is the resolution the
    /// histogram has, not an error the arithmetic can remove.
    static func clusterWatts(_ states: [(String, Int64)]) -> (Double, Double) {
        var lower = 0.0, weighted = 0.0, ticks = 0.0
        for (name, residency) in states {
            let t = name.trimmingCharacters(in: .whitespaces)
            guard t.hasSuffix("W"), let upper = Double(t.dropLast()) else { continue }
            let r = Double(residency)
            weighted += r * (lower + upper) / 2; ticks += r; lower = upper
        }
        return (weighted, ticks)
    }

    private static func coreSortKey(_ ch: String) -> (Int, Int, Int, Int) {
        var die = 0
        if ch.hasPrefix("DIE_"), let d = Int(ch.dropFirst(4).prefix { $0.isNumber }) { die = d }
        let tier = ch.contains("ECPU") ? 0 : ch.contains("MCPU") ? 1 : 2
        let prefix = ["ECPU", "MCPU", "PCPU"].first { ch.contains($0) } ?? ""
        let rest = ch[(ch.range(of: prefix)?.upperBound ?? ch.endIndex)...]
        if let r = rest.range(of: "_CPU") {
            let cluster = Int(rest[..<r.lowerBound]) ?? 0
            let core = Int(rest[r.upperBound...].prefix { $0.isNumber }) ?? 0
            return (die, tier, cluster, core)
        }
        return (die, tier, 0, Int(rest.prefix { $0.isNumber }) ?? 0)
    }
}
