import AppKit
import SwiftUI

@main
enum PWEMacMonitorMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--probe") || args.contains("--json") { CLI.run(json: args.contains("--json"), loop: args.contains("--loop")); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var monitor: Monitor!
    private let updater = UpdateCheck()

    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = Monitor()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(click(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageOnly
            b.toolTip = "PWE Monitor"
        }
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: DashboardView(monitor: monitor))
        // Without this an NSHostingController never publishes `preferredContentSize`, and NSPopover
        // — which sizes itself from exactly that — falls back to its own 320×320 default. The
        // dashboard then opens cropped to 320 pt regardless of how tall its content is.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        monitor.onUpdate = { [weak self] in self?.refreshIcon() }
        monitor.presentMenu = { [weak self] view in self?.presentSettingsMenu(from: view) }
        // Light/dark can change between samples; redraw the glyph the moment it does rather than
        // leaving a white-on-white icon until the next tick.
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.refreshIcon() }
        }
        refreshIcon()
        if !CommandLine.arguments.contains("--snapshot"), !CommandLine.arguments.contains("--popover-test"),
           !CommandLine.arguments.contains("--wing-states"), !CommandLine.arguments.contains("--bench-icon"),
           !CommandLine.arguments.contains("--updatecheck") {
            Install.offerToInstallIfNeeded()
            Install.offerToRemovePredecessorIfNeeded()
        }
        // After the interface is up, and never during a snapshot run: a screenshot must not
        // depend on what a server says today.
        if !CommandLine.arguments.contains("--snapshot"), !CommandLine.arguments.contains("--updatecheck") {
            Task { [weak self] in
                guard let self else { return }
                await self.updater.checkIfDue(enabled: self.monitor.updateChecks)
                self.refreshIcon()
            }
        }
        if CommandLine.arguments.contains("--open") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.openPopover() } }
        if CommandLine.arguments.contains("--popover-test") { runPopoverTest() }
        if CommandLine.arguments.contains("--bench-icon") { WingStatesCheck.bench(); NSApp.terminate(nil) }
        if CommandLine.arguments.contains("--updatecheck") { exit(UpdateCheckSelfTest.run()) }
        if let i = CommandLine.arguments.firstIndex(of: "--wing-states"), i + 1 < CommandLine.arguments.count {
            WingStatesCheck.write(to: CommandLine.arguments[i + 1])
            NSApp.terminate(nil)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            let wait = CommandLine.arguments.contains("--warm") ? 95.0 : 8.0
            // A run-loop timer, not DispatchQueue.main.asyncAfter: the capture spins a nested run
            // loop, and the serial main queue will not re-enter to deliver other blocks while one of
            // its own is still executing — results posted back from worker queues would never land.
            Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
                MainActor.assumeIsolated {
                    self.monitor.isOpen = true
                    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            self.writeSnapshots(to: dir)
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    /// Reproduces what the user actually sees: an NSPopover takes its size from the content view
    /// controller's `preferredContentSize`, not from the SwiftUI view's fitting size, so measuring
    /// an NSHostingView in isolation proves nothing about whether the popover opens at full height.
    /// Prints the popover window height right after `show` and again as it settles.
    private func runPopoverTest() {
        Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
          MainActor.assumeIsolated {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            window.contentView?.addSubview(anchor)
            window.setFrameOrigin(NSPoint(x: 200, y: 200))
            window.orderFront(nil)

            self.monitor.isOpen = true
            self.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

            @MainActor func report(_ label: String) {
                let content = self.popover.contentSize.height
                let preferred = self.popover.contentViewController?.preferredContentSize.height ?? -1
                let frame = self.popover.contentViewController?.view.frame.height ?? -1
                print(String(format: "  %-14@ contentSize %6.0f · preferred %6.0f · view %6.0f",
                             label as NSString, content, preferred, frame))
            }
            print("popover height over time (expect one stable number):")
            report("t=0")
            // Also exercise the dynamic case: turning the sensor panel on and off changes the
            // content height, and the popover has to follow it without a stale frame in between.
            var steps: [(String, () -> Void)] = [
                ("settled", {}),
                ("sensors on", { self.monitor.showSensors = true }),
                ("one tick later", {}),
                ("sensors off", { self.monitor.showSensors = false }),
                ("one tick later", {}),
            ]
            @MainActor func schedule() {
                guard !steps.isEmpty else { NSApp.terminate(nil); return }
                let (label, action) = steps.removeFirst()
                action()
                Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                    MainActor.assumeIsolated { report(label); schedule() }
                }
            }
            schedule()
          }
        }
    }

    /// Debug aid: renders the dashboard and the menu-bar glyph to PNG files in both appearances.
    /// Documentation screenshots go into a public repository, so `--demo` substitutes the two
    /// things that would otherwise publish the author's environment: the running process names and
    /// the local IP address. Every other figure is real.
    private func demoSubstitutions() {
        guard CommandLine.arguments.contains("--demo") else { return }
        monitor.applyDemoRedaction(processes: [
            ("Xcode", 14.8, 1_930_000_000), ("Final Cut Pro", 9.2, 2_640_000_000),
            ("Safari", 6.4, 812_000_000), ("Logic Pro", 4.1, 1_180_000_000),
            ("Docker Desktop", 2.6, 604_000_000), ("Spotlight", 1.3, 96_000_000),
        ], address: "192.168.1.42")
    }

    private func writeSnapshots(to dir: String) {
        demoSubstitutions()
        for (name, appearance, dark) in [("dark", NSAppearance.Name.darkAqua, true), ("light", NSAppearance.Name.aqua, false)] {
            let host = NSHostingView(rootView: DashboardView(monitor: monitor))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            win.appearance = host.appearance
            host.layoutSubtreeIfNeeded()
            // The popover is sized from the very first layout pass — no settling round-trip. Report
            // both so a regression back to measure-then-resize is obvious here rather than in use.
            let firstPass = host.fittingSize.height
            for _ in 0..<3 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                win.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
            }
            let settled = host.fittingSize.height
            print(String(format: "%@: first layout %.0f pt, settled %.0f pt%@  · sensors %d · processes %d",
                         name, firstPass, settled, abs(firstPass - settled) < 1 ? " — stable" : "  ⚠️ RESIZES AFTER SHOW",
                         monitor.sensorList.count, monitor.snap.processes.count))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/dashboard-\(name).png"))
            for mode in MenuBarMode.allCases {
                let img = StatusIcon.render(monitor.snap, channels: monitor.channels, overall: monitor.overall, powerHealth: monitor.powerHealth, mode: mode, dark: dark)
                let scaled = NSImage(size: NSSize(width: img.size.width * 4, height: img.size.height * 4), flipped: false) { r in
                    (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); r.fill()
                    img.draw(in: r); return true }
                if let t = scaled.tiffRepresentation, let r = NSBitmapImageRep(data: t) {
                    try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/menubar-\(mode.rawValue)-\(name).png"))
                }
            }
        }
    }

    private func refreshIcon() {
        guard let b = statusItem.button else { return }
        let dark = b.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        b.image = StatusIcon.render(monitor.snap, channels: monitor.channels, overall: monitor.overall, powerHealth: monitor.powerHealth, mode: monitor.menuBarMode, dark: dark)
        let s = monitor.snap
        b.toolTip = String(format: "CPU %.0f%% · GPU %.0f%% · %.1f W · CPU %.0f° · GPU %.0f° · SSD %.0f°", s.cpuUsage * 100, s.gpuUsage * 100, s.sysPower, s.cpuTempMax, s.gpuTemp, s.ssdTemp)
    }

    @objc private func click(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(from: sender); return }
        if popover.isShown { popover.performClose(nil) } else { openPopover() }
    }

    private func openPopover() {
        guard let b = statusItem.button else { return }
        monitor.isOpen = true
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Assigning `statusItem.menu` and then synthesising a click is the usual shortcut here, but it
    /// permanently rebinds the button's action and the left-click popover stops working. Pop the
    /// menu up directly instead.
    private func showMenu(from button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) }
        let menu = buildMenu(includeOpen: true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
    }

    /// Same menu from the status item's right-click and from the dashboard's settings button.
    private func presentSettingsMenu(from view: NSView) {
        let menu = buildMenu(includeOpen: false)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
    }

    private func buildMenu(includeOpen: Bool) -> NSMenu {
        let menu = NSMenu()
        if includeOpen {
            let open = menu.addItem(withTitle: L("menu.open", "Open Dashboard"), action: #selector(openFromMenu), keyEquivalent: "")
            open.target = self
            menu.addItem(.separator())
        }

        let modes = NSMenu()
        for m in MenuBarMode.allCases {
            let it = modes.addItem(withTitle: m.label, action: #selector(setMode(_:)), keyEquivalent: "")
            it.representedObject = m.rawValue
            it.state = monitor.menuBarMode == m ? .on : .off
            it.target = self
        }
        menu.setSubmenu(modes, for: menu.addItem(withTitle: L("menu.style", "Menu Bar Style"), action: nil, keyEquivalent: ""))

        let intervals = NSMenu()
        for v in [1.0, 2.0, 3.0, 5.0] {
            let title = v == 1 ? L("menu.interval.one", "1 second")
                               : String(format: L("menu.interval.many", "%d seconds"), Int(v))
            let it = intervals.addItem(withTitle: title, action: #selector(setInterval(_:)), keyEquivalent: "")
            it.representedObject = v
            it.state = monitor.interval == v ? .on : .off
            it.target = self
        }
        menu.setSubmenu(intervals, for: menu.addItem(withTitle: L("menu.refresh", "Refresh Every"), action: nil, keyEquivalent: ""))

        let languages = NSMenu()
        for l in Language.allCases {
            let it = languages.addItem(withTitle: l.label, action: #selector(setLanguage(_:)), keyEquivalent: "")
            it.representedObject = l.rawValue
            it.state = monitor.language == l ? .on : .off
            it.target = self
        }
        menu.setSubmenu(languages, for: menu.addItem(withTitle: L("menu.language", "Language"), action: nil, keyEquivalent: ""))

        // Panel sections. The unit is a grid row rather than a card because a GridRow takes the
        // height of its taller card — hiding one of a pair reclaims nothing.
        let sections = NSMenu()
        for (key, title, on) in [
            ("thermalMemory", L("section.thermalMemory", "Thermals & Memory"), monitor.showThermalMemory),
            ("fansBattery", L("section.fansBattery", "Fans & Battery"), monitor.showFansBattery),
            ("storageNetwork", L("section.storageNetwork", "Storage & Network"), monitor.showStorageNetwork),
            ("processes", L("section.processes", "Top Processes"), monitor.showProcesses),
            ("sensors", L("menu.sensors", "All Sensors"), monitor.showSensors),
        ] {
            let it = sections.addItem(withTitle: title, action: #selector(toggleSection(_:)), keyEquivalent: "")
            it.representedObject = key
            it.state = on ? .on : .off
            it.target = self
        }
        menu.setSubmenu(sections, for: menu.addItem(withTitle: L("menu.sections", "Panel Sections"), action: nil, keyEquivalent: ""))

        menu.addItem(.separator())
        let login = menu.addItem(withTitle: L("menu.login", "Launch at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = monitor.launchAtLogin ? .on : .off
        login.target = self

        menu.addItem(.separator())
        // Seeing which process is pegging a core is half the job; the other half is going and
        // dealing with it, and this app deliberately cannot kill anything.
        let activity = menu.addItem(withTitle: L("menu.activity", "Open Activity Monitor"), action: #selector(openActivityMonitor), keyEquivalent: "")
        activity.target = self
        let copy = menu.addItem(withTitle: L("menu.copy", "Copy Diagnostics"), action: #selector(copyDiagnostics), keyEquivalent: "")
        copy.target = self

        menu.addItem(.separator())
        // Two items, because they answer two different questions. The first is "is there a
        // newer one" — asked now, by someone who asked. Pressing it is that check's consent, so
        // it needs no switch in front of it. The second is "tell me without my asking", which
        // does, and is off until it is turned on.
        //
        // Until 1.3.0 the first item opened the GitHub releases page and left the reader to
        // compare version numbers. That is a link, not a check.
        let updates = menu.addItem(
            withTitle: updater.available.map {
                String(format: L("menu.updateReady", "Download version %@…"), $0.version)
            } ?? L("menu.updates", "Check for Updates…"),
            action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        let autoUpdates = menu.addItem(withTitle: L("menu.updatesAuto", "Check automatically"),
                                       action: #selector(toggleUpdateChecks), keyEquivalent: "")
        autoUpdates.state = monitor.updateChecks ? .on : .off
        autoUpdates.target = self
        let source = menu.addItem(withTitle: L("menu.source", "Source Code on GitHub"), action: #selector(openRepository), keyEquivalent: "")
        source.target = self
        let version = menu.addItem(withTitle: String(format: L("menu.version", "Version %@"), Install.version), action: nil, keyEquivalent: "")
        version.isEnabled = false

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L("menu.quit", "Quit PWE Monitor"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return menu
    }

    @objc private func openFromMenu() { openPopover() }
    @objc private func toggleSection(_ item: NSMenuItem) {
        switch item.representedObject as? String {
        case "thermalMemory":  monitor.showThermalMemory.toggle()
        case "fansBattery":    monitor.showFansBattery.toggle()
        case "storageNetwork": monitor.showStorageNetwork.toggle()
        case "processes":      monitor.showProcesses.toggle()
        case "sensors":        monitor.showSensors.toggle()
        default: break
        }
    }
    @objc private func toggleUpdateChecks() {
        monitor.updateChecks.toggle()
        if monitor.updateChecks { Task { await updater.check() } }
    }

    /// The manual check. Always says something — an answer that arrives silently is
    /// indistinguishable from a menu item that does nothing.
    @objc private func checkForUpdates() {
        if let release = updater.available { return present(release) }
        Task { @MainActor in
            let answered = await updater.check()
            NSApp.activate(ignoringOtherApps: true)
            if let release = updater.available { return present(release) }
            let alert = NSAlert()
            alert.alertStyle = .informational
            if answered {
                alert.messageText = L("update.current", "PWE Monitor is up to date.")
                alert.informativeText = String(format: L("update.currentVersion", "Version %@"),
                                               UpdateCheck.currentVersion)
            } else {
                alert.messageText = L("update.unreachable", "Could not reach pwestudio.site.")
                // One line: loccheck scans for `L("key", "English")` within a line, so a call
                // wrapped across two is a key it never sees and therefore never gates.
                alert.informativeText = L("update.tryAgain", "Check your connection and try again, or open the download page.")
                alert.addButton(withTitle: L("update.openPage", "Open Download Page"))
                alert.addButton(withTitle: L("update.ok", "OK"))
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(UpdateCheck.downloadPage)
                }
                return
            }
            alert.runModal()
        }
    }

    @MainActor private func present(_ release: UpdateCheck.Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: L("update.ready", "Version %@ is out."), release.version)
        alert.informativeText = release.notes
            ?? String(format: L("update.youHave", "You have %@."), UpdateCheck.currentVersion)
        // A button, not a command. Someone who has to be told to open Terminal and type
        // `brew upgrade` is someone who stays on the version with the bug.
        alert.addButton(withTitle: L("update.download", "Download"))
        alert.addButton(withTitle: L("update.later", "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(UpdateCheck.downloadPage)
        } else {
            updater.dismiss()
        }
    }

    @objc private func openRepository() { NSWorkspace.shared.open(Install.repositoryURL) }
    @objc private func toggleLaunchAtLogin() { monitor.launchAtLogin.toggle() }
    @objc private func setMode(_ item: NSMenuItem) {
        if let r = item.representedObject as? String, let m = MenuBarMode(rawValue: r) { monitor.menuBarMode = m }
    }
    @objc private func setInterval(_ item: NSMenuItem) {
        if let v = item.representedObject as? Double { monitor.interval = v }
    }
    @objc private func setLanguage(_ item: NSMenuItem) {
        if let r = item.representedObject as? String, let l = Language(rawValue: r) { monitor.language = l }
    }
    @objc private func openActivityMonitor() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }
    /// Deliberately the `--probe` text, in English, whatever the interface language: it goes into
    /// a bug report or a message to us, and a reading is easier to act on in the form the CLI and
    /// the JSON already use.
    @objc private func copyDiagnostics() {
        guard let soc = monitor.soc else { return }
        let text = "PWE Monitor \(Install.version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            + CLI.summary(monitor.snap, soc: soc)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func popoverDidClose(_ notification: Notification) { monitor.isOpen = false }
    func popoverDidShow(_ notification: Notification) { monitor.isOpen = true }
}

/// `pwemon --probe` prints a human summary; `--json [--loop]` streams JSON (one object per line) for scripts.
enum CLI {
    static func run(json: Bool, loop: Bool) {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let sampler = Sampler() else { FileHandle.standardError.write("Hardware sources unavailable (Apple Silicon required)\n".data(using: .utf8)!); exit(1) }
        // The CLI is the machine-readable surface: always emit the complete sensor list.
        _ = sampler.sample(interval: 1, allSensors: true)
        repeat {
            Thread.sleep(forTimeInterval: 1)
            let s = sampler.sample(interval: 1, allSensors: true)
            if json { print(encode(s, soc: sampler.soc)) } else { print(summary(s, soc: sampler.soc)) }
        } while loop
    }

    static func summary(_ s: Snapshot, soc: SocInfo) -> String {
        """
        \(soc.chipName) · \(soc.memoryGB) GB · \(soc.ecpuLabel)\(soc.ecpuCores)+\(soc.pcpuLabel)\(soc.pcpuCores) · GPU \(soc.gpuCores)
        CPU   \(Fmt.pct(s.cpuUsage))  E \(s.ecpuFreq) MHz  P \(s.pcpuFreq) MHz  temp avg \(Fmt.temp1(s.cpuTemp)) max \(Fmt.temp1(s.cpuTempMax))
        GPU   \(Fmt.pct(s.gpuUsage))  \(s.gpuFreq) MHz  temp \(Fmt.temp1(s.gpuTemp))
        Power sys \(Fmt.watts(s.sysPower))  cpu \(Fmt.watts(s.cpuPower))  gpu \(Fmt.watts(s.gpuPower))  ane \(Fmt.watts(s.anePower))  ram \(Fmt.watts(s.ramPower))
        SSD   \(Fmt.temp1(s.ssdTemp))  r \(Fmt.rate(s.diskReadPerSec))  w \(Fmt.rate(s.diskWritePerSec))  used \(Fmt.bytes(Double(s.disk.total - s.disk.free))) / \(Fmt.bytes(Double(s.disk.total)))
        Fans  \(s.fans.map { "\($0.id) \($0.rpm) rpm" }.joined(separator: ", "))
        Mem   \(Fmt.gib(s.memory.used)) / \(Fmt.gib(s.memory.total))  swap \(Fmt.gib(s.memory.swapUsed))  pressure \(s.memory.pressure)
        Net   ↓ \(Fmt.rate(s.netInPerSec))  ↑ \(Fmt.rate(s.netOutPerSec))
        Batt  \(s.battery.present ? "\(s.battery.percent)% \(String(format: "%+.1f", s.battery.watts)) W \(Fmt.temp1(s.battery.temperature)) cycles \(s.battery.cycles)" : "none")
        """
    }

    static func encode(_ s: Snapshot, soc: SocInfo) -> String {
        let obj: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: s.time), "chip": soc.chipName,
            "cpu": ["usage": s.cpuUsage, "active": s.cpuActive, "ecpu_mhz": s.ecpuFreq, "pcpu_mhz": s.pcpuFreq, "temp_avg": s.cpuTemp, "temp_max": s.cpuTempMax, "power_w": s.cpuPower,
                    "cores": s.cores.map { ["id": $0.id, "p": $0.isP, "mhz": $0.freqMHz, "usage": $0.scaled] }],
            "gpu": ["usage": s.gpuUsage, "mhz": s.gpuFreq, "temp": s.gpuTemp, "power_w": s.gpuPower],
            "power": ["sys_w": s.sysPower, "ane_w": s.anePower, "ram_w": s.ramPower, "all_w": s.allPower],
            "ssd": ["temp": s.ssdTemp, "read_bps": s.diskReadPerSec, "write_bps": s.diskWritePerSec, "total": s.disk.total, "free": s.disk.free],
            "fans": s.fans.map { ["name": $0.id, "rpm": $0.rpm, "max_rpm": $0.maxRPM ?? 0] },
            "memory": ["total": s.memory.total, "used": s.memory.used, "wired": s.memory.wired, "compressed": s.memory.compressed, "swap_used": s.memory.swapUsed, "pressure": s.memory.pressure],
            "network": ["in_bps": s.netInPerSec, "out_bps": s.netOutPerSec],
            "battery": ["present": s.battery.present, "percent": s.battery.percent, "watts": s.battery.watts, "temp": s.battery.temperature, "cycles": s.battery.cycles, "health": s.battery.health],
            "sensors": Dictionary(s.sensors.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a }),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
