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

    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = Monitor()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(click(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageOnly
            b.toolTip = "PWE MAC MONITOR"
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
        if !CommandLine.arguments.contains("--snapshot"), !CommandLine.arguments.contains("--popover-test") {
            Install.offerToInstallIfNeeded()
        }
        if CommandLine.arguments.contains("--open") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.openPopover() } }
        if CommandLine.arguments.contains("--popover-test") { runPopoverTest() }
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
                let img = StatusIcon.render(monitor.snap, overall: monitor.overall, powerHealth: monitor.powerHealth, mode: mode, dark: dark)
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
        b.image = StatusIcon.render(monitor.snap, overall: monitor.overall, powerHealth: monitor.powerHealth, mode: monitor.menuBarMode, dark: dark)
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
            let open = menu.addItem(withTitle: "Open Dashboard", action: #selector(openFromMenu), keyEquivalent: "")
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
        menu.setSubmenu(modes, for: menu.addItem(withTitle: "Menu Bar Style", action: nil, keyEquivalent: ""))

        let intervals = NSMenu()
        for v in [1.0, 2.0, 3.0, 5.0] {
            let it = intervals.addItem(withTitle: "\(Int(v)) second\(v == 1 ? "" : "s")",
                                       action: #selector(setInterval(_:)), keyEquivalent: "")
            it.representedObject = v
            it.state = monitor.interval == v ? .on : .off
            it.target = self
        }
        menu.setSubmenu(intervals, for: menu.addItem(withTitle: "Refresh Every", action: nil, keyEquivalent: ""))

        menu.addItem(.separator())
        let sensors = menu.addItem(withTitle: "Show All Sensors", action: #selector(toggleSensors), keyEquivalent: "")
        sensors.state = monitor.showSensors ? .on : .off
        sensors.target = self
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = monitor.launchAtLogin ? .on : .off
        login.target = self

        menu.addItem(.separator())
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(openReleases), keyEquivalent: "")
        updates.target = self
        let source = menu.addItem(withTitle: "Source Code on GitHub", action: #selector(openRepository), keyEquivalent: "")
        source.target = self
        let version = menu.addItem(withTitle: "Version \(Install.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit PWE MAC MONITOR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return menu
    }

    @objc private func openFromMenu() { openPopover() }
    @objc private func toggleSensors() { monitor.showSensors.toggle() }
    @objc private func openReleases() { NSWorkspace.shared.open(Install.releasesURL) }
    @objc private func openRepository() { NSWorkspace.shared.open(Install.repositoryURL) }
    @objc private func toggleLaunchAtLogin() { monitor.launchAtLogin.toggle() }
    @objc private func setMode(_ item: NSMenuItem) {
        if let r = item.representedObject as? String, let m = MenuBarMode(rawValue: r) { monitor.menuBarMode = m }
    }
    @objc private func setInterval(_ item: NSMenuItem) {
        if let v = item.representedObject as? Double { monitor.interval = v }
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
