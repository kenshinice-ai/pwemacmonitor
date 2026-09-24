import Foundation
import Combine
import AppKit
import ServiceManagement

enum MenuBarMode: String, CaseIterable, Identifiable {
    case icon, compact, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .icon: return L("menubar.icon", "Wing only")
        case .compact: return L("menubar.compact", "Power + temperature")
        case .full: return L("menubar.full", "CPU + power + temperature")
        }
    }
}

/// The two conditions worth putting a banner on the panel for. Held as a case rather than as a
/// finished sentence so that switching language re-renders the text that is already on screen.
enum AppError {
    case noAppleSilicon, launchAtLogin
    var message: String {
        switch self {
        case .noAppleSilicon:
            return L("error.hardware", "Hardware sources unavailable — PWE Monitor needs an Apple Silicon Mac.")
        case .launchAtLogin:
            return L("error.login", "Could not set launch at login — move the app to /Applications and try again.")
        }
    }
}

/// Owns the sampler thread, publishes snapshots to the UI, and persists settings.
///
/// `snap` and `history` are plain properties rather than `@Published`: while the popover is closed
/// nothing is on screen, so republishing every couple of seconds would re-run the whole SwiftUI body
/// for no reason. `revision` is the single published signal, and it only advances while the popover
/// is open — which is also when the sampler collects the expensive detail (process table, full
/// sensor list).
/// A boolean shared between the main actor and the sampler queue.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

@MainActor
final class Monitor: ObservableObject {
    private(set) var snap = Snapshot()
    /// Held apart from `snap` on purpose: a sample that was already in flight when the panel opened
    /// lands carrying an empty sensor list, and would otherwise wipe the on-demand read that the
    /// panel just did.
    private(set) var sensorList: [Sensor] = []
    private(set) var history: [String: [Double]] = ["cpu": [], "gpu": [], "power": [], "temp": [], "mem": []]
    @Published private(set) var revision = 0
    @Published private(set) var error: AppError?

    @Published var interval: Double { didSet { defaults.set(interval, forKey: "interval"); restart() } }
    @Published var menuBarMode: MenuBarMode { didSet { defaults.set(menuBarMode.rawValue, forKey: "menuBarMode"); onUpdate?() } }
    @Published var showSensors: Bool { didSet { defaults.set(showSensors, forKey: "showSensors"); syncSensorPanel(); bump() } }

    /// Cards switched off in Panel Sections. Per card rather than per grid row since 1.5.0: the
    /// grid now pairs whatever is left, so hiding one card reflows the others and reclaims its
    /// row — under the fixed pairing it only left a padded hole beside its partner, which is
    /// why 1.3.0 grouped the switches by row.
    ///
    /// Settings menu rather than chevrons on the panel: the resting interface is unchanged, it
    /// costs no height, and it is the pattern `showSensors` has used since 1.0.
    @Published var hiddenCards: Set<PanelCard> {
        didSet { defaults.set(hiddenCards.map(\.rawValue).sorted(), forKey: "hiddenCards"); bump() }
    }
    /// What the machine has. Fixed at launch — see `Hardware`.
    let hardware: Hardware

    /// Present on this Mac and not switched off.
    func shows(_ card: PanelCard) -> Bool { hardware.has(card) && !hiddenCards.contains(card) }
    func toggle(_ card: PanelCard) {
        if hiddenCards.contains(card) { hiddenCards.remove(card) } else { hiddenCards.insert(card) }
    }
    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }
    /// Whether the app may ask the site once a day whether a newer version exists. Off until it
    /// is turned on; pressing "Check for Updates…" is a separate, one-off consent.
    @Published var updateChecks: Bool { didSet { defaults.set(updateChecks, forKey: "updateChecks") } }
    @Published var language: Language {
        didSet { defaults.set(language.rawValue, forKey: "language"); Loc.language = language; onUpdate?(); bump() }
    }

    /// Set by the app delegate when the popover opens or closes.
    var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            syncSensorPanel()
            if isOpen { bump() }
        }
    }

    /// Read from the sampler thread, so it lives behind a lock rather than on the main actor —
    /// a `DispatchQueue.main.sync` from the timer would deadlock the moment the main thread
    /// waited on anything the sampler holds.
    private let wantsAllSensors = LockedFlag()

    var onUpdate: (() -> Void)?
    /// Supplied by the app delegate: pops the shared settings menu, anchored to the given view.
    var presentMenu: ((NSView) -> Void)?
    let soc: SocInfo?
    let sampler: Sampler?
    private let queue = DispatchQueue(label: "au.com.pwe.macmonitor.sampler", qos: .utility)
    /// Separate from `queue`: the sampler spends its interval asleep inside IOReport, so a one-shot
    /// read scheduled behind it would not run until the next tick — up to five seconds of "Reading…".
    private let sensorQueue = DispatchQueue(label: "au.com.pwe.macmonitor.sensors", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let defaults = UserDefaults.standard

    init() {
        let stored = defaults.double(forKey: "interval")
        interval = [1.0, 2.0, 3.0, 5.0].contains(stored) ? stored : 2
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .full
        showSensors = defaults.bool(forKey: "showSensors")
        hiddenCards = Monitor.storedHiddenCards()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        updateChecks = defaults.bool(forKey: "updateChecks")
        // Through a local: the compiler will not let `Loc` read back `self.language` until every
        // stored property is up, and the string tables have to be pointed at the right language
        // before anything below builds a label out of them.
        let lang = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        language = lang
        Loc.language = lang
        sampler = Sampler()
        soc = sampler?.soc
        hardware = Monitor.hardwareOverride() ?? sampler?.hardware ?? .laptop
        if sampler == nil { error = .noAppleSilicon }
        restart()
    }

    /// 1.3.0 stored switches per grid row under `section.*`. Carried across once, card by card,
    /// so nobody who turned a row off finds it back after upgrading.
    private static func storedHiddenCards() -> Set<PanelCard> {
        let d = UserDefaults.standard
        if let saved = d.stringArray(forKey: "hiddenCards") {
            return Set(saved.compactMap(PanelCard.init(rawValue:)))
        }
        var hidden: Set<PanelCard> = []
        let rows: [(String, [PanelCard])] = [("thermalMemory", [.thermals, .memory]), ("fansBattery", [.fans, .battery]),
                                             ("storageNetwork", [.storage, .network]), ("processes", [.processes])]
        for (key, cards) in rows where d.object(forKey: "section." + key) as? Bool == false {
            hidden.formUnion(cards)
        }
        return hidden
    }

    /// `PWEMON_HARDWARE=desktop` or `=fanless` renders another machine's layout on this one, for
    /// the documentation screenshots and for checking a layout that no Mac at hand can produce.
    /// Only the card set changes; every reading is still this machine's.
    private static func hardwareOverride() -> Hardware? {
        switch ProcessInfo.processInfo.environment["PWEMON_HARDWARE"] {
        case "desktop": return Hardware(hasBattery: false, hasFans: true)
        case "fanless": return Hardware(hasBattery: true, hasFans: false)
        case "laptop":  return .laptop
        default: return nil
        }
    }

    var overall: Health { snap.overall(chipClass: soc?.chipClass ?? "Base") }
    /// The five wing channels. Everything that shows a band reads from here.
    var channels: [ChannelHealth] { snap.channels(chipClass: soc?.chipClass ?? "Base") }
    var powerHealth: Health { snap.powerHealth(chipClass: soc?.chipClass ?? "Base") }

    func restart() {
        timer?.cancel()
        guard let sampler else { return }
        let iv = interval
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: iv, leeway: .milliseconds(50))
        let wantsAll = self.wantsAllSensors
        t.setEventHandler { [weak self] in
            // Reading `isOpen` needs the main actor; capture it, then sample off it.
            let s = sampler.sample(interval: iv, allSensors: wantsAll.value)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish(s) } }
        }
        t.resume()
        timer = t
    }

    private func publish(_ s: Snapshot) {
        snap = s
        applyDemo()
        if !s.sensors.isEmpty { sensorList = s.sensors }
        push("cpu", s.cpuUsage); push("gpu", s.gpuUsage); push("power", s.sysPower)
        push("temp", s.cpuTempMax); push("mem", s.memory.usedRatio)
        onUpdate?()                 // the menu-bar glyph always refreshes
        if isOpen { bump() }        // the dashboard only when someone is looking
    }

    private func bump() { revision &+= 1 }

    /// Used only by `--snapshot --demo` when producing documentation images.
    func applyDemoRedaction(processes: [(String, Double, UInt64)], address: String) {
        demoProcesses = processes.enumerated().map {
            ProcessStat(pid: Int32(-1 - $0.offset), name: $0.element.0,
                        cpuPercent: $0.element.1, memoryBytes: $0.element.2)
        }
        demoAddress = address
        applyDemo()
        bump()
    }
    private var demoProcesses: [ProcessStat] = []
    private var demoAddress: String?
    private func applyDemo() {
        guard !demoProcesses.isEmpty else { return }
        snap.processes = demoProcesses
        if let demoAddress { snap.network.primaryAddress = demoAddress }
    }

    /// The sensor sweep is expensive, so it only runs while the panel is on screen. Opening the
    /// panel also kicks off one immediate read — otherwise the list would sit empty until the next
    /// sample, which at a 5 s refresh is a visibly broken-looking wait.
    private func syncSensorPanel() {
        let wanted = isOpen && showSensors
        wantsAllSensors.value = wanted
        guard wanted, let sampler else { return }
        sensorQueue.async { [weak self] in
            let sensors = sampler.readAllSensors()
            // GCD rather than `Task { @MainActor }`: a nested run loop drains the main dispatch
            // queue but does not service main-actor task continuations, which made this silently
            // never arrive in some run-loop states.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sensorList = sensors
                    self.bump()
                }
            }
        }
    }

    private func push(_ k: String, _ v: Double) {
        var a = history[k] ?? []
        a.append(v)
        if a.count > Theme.historyLength { a.removeFirst(a.count - Theme.historyLength) }
        history[k] = a
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            // Most often this is an app running from a location LaunchServices will not register,
            // such as iCloud Drive or a quarantined download.
            launchAtLogin = SMAppService.mainApp.status == .enabled
            self.error = .launchAtLogin
        }
    }
}
