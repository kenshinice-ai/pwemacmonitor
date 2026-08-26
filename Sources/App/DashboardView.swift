import SwiftUI

/// The popover: a brand header, a scrolling body, and a control bar.
///
/// Sizing is settled in a single layout pass. `.fixedSize(vertical:)` makes the scroll view adopt
/// its content's own height — a scroll view otherwise just accepts whatever height it is offered —
/// and `.frame(maxHeight:)` then clamps that to what the display can show. Measuring the content
/// with a GeometryReader and feeding the result back into the frame *looks* equivalent, but the
/// answer only arrives after the popover has already sized its window, so the window stayed at its
/// initial guess until some later update happened to trigger another resize: at a 5 s refresh that
/// showed up as the popover opening cropped and snapping to full height ten seconds later.
///
/// Every card also has a constant height regardless of the values inside it, so the popover never
/// resizes between refreshes.
struct DashboardView: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var s: Snapshot { monitor.snap }

    /// Leaves room for the menu bar, the popover arrow and a margin at the bottom of the screen.
    /// `PWEMON_MAX_BODY` overrides it, so the small-screen path can be exercised on a large display.
    private var maxBodyHeight: CGFloat {
        if let override = ProcessInfo.processInfo.environment["PWEMON_MAX_BODY"], let v = Double(override) {
            return CGFloat(v)
        }
        return max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 190)
    }

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader(monitor: monitor, dark: dark)
            Divider().overlay(Theme.stroke(dark))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    if let e = monitor.error { banner(e) }
                    hero
                    silicon
                    HStack(alignment: .top, spacing: Theme.s3) { thermals; rightColumn }
                    processes
                    if monitor.showSensors { sensors }
                    signature
                }
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s3)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            // Order matters: the clamp has to sit *inside* fixedSize. The other way round, the
            // scroll view ignores the parent's proposal entirely and overflows the screen.
            .frame(maxHeight: maxBodyHeight)
            .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.stroke(dark))
            ControlBar(monitor: monitor, dark: dark)
        }
        .frame(width: Theme.width)
        .background(Theme.background(dark))
        .foregroundStyle(Theme.ink(dark))
        .animation(.easeInOut(duration: 0.18), value: monitor.showSensors)
    }

    private func banner(_ e: String) -> some View {
        Text(e).font(Theme.ui(11)).padding(Theme.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.health(.hot, dark: dark).opacity(0.14)))
    }

    // MARK: Hero — CPU · GPU · Power
    private var hero: some View {
        Card(dark: dark) {
            HStack(alignment: .top, spacing: 0) {
                heroStat("CPU", Fmt.pct(s.cpuUsage), Fmt.ghz(s.pcpuFreq), Fmt.temp(s.cpuTempMax), s.cpuTempMaxHealth,
                         s.cpuLoadHealth, monitor.history["cpu"] ?? [], ceiling: 1)
                rule
                heroStat("GPU", Fmt.pct(s.gpuUsage), s.gpuFreq > 0 ? "\(s.gpuFreq) MHz" : "idle",
                         s.gpuTemp > 0 ? Fmt.temp(s.gpuTemp) : nil, s.gpuTempHealth,
                         s.gpuLoadHealth, monitor.history["gpu"] ?? [], ceiling: 1)
                rule
                heroStat("POWER", Fmt.watts(s.sysPower), "chip \(Fmt.watts(s.allPower))", nil, .calm,
                         monitor.powerHealth, monitor.history["power"] ?? [], ceiling: nil)
            }
        }
    }
    private var rule: some View { Rectangle().fill(Theme.stroke(dark)).frame(width: 1, height: 66).padding(.horizontal, Theme.s3) }

    private func heroStat(_ title: String, _ value: String, _ sub: String, _ temp: String?, _ tempHealth: Health,
                          _ h: Health, _ series: [Double], ceiling: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(title, dark: dark, ruled: false)
            Text(value).font(Theme.number(21, 600)).foregroundStyle(Theme.health(h, dark: dark))
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack(spacing: 3) {
                Text(sub).font(Theme.number(8.5, 400)).foregroundStyle(Theme.muted(dark))
                if let temp {
                    Text("·").font(Theme.number(8.5, 400)).foregroundStyle(Theme.muted(dark))
                    Text(temp).font(Theme.number(8.5, 600)).foregroundStyle(Theme.health(tempHealth, dark: dark))
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            Sparkline(values: series, ceiling: ceiling, color: Theme.healthFill(h, dark: dark)).frame(height: 21).padding(.top, 2)
                .help("Last \(Theme.historyLength) samples · \(Int(Double(Theme.historyLength) * monitor.interval / 60)) min at \(Int(monitor.interval))s")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Thermals
    private var thermals: some View {
        VStack(spacing: Theme.s3) {
            Card(dark: dark, title: "THERMALS") {
                VStack(spacing: 7) {
                    gauge("CPU avg", s.cpuTemp, s.cpuTempHealth)
                    gauge("CPU max", s.cpuTempMax, s.cpuTempMaxHealth)
                    gauge("GPU", s.gpuTemp, s.gpuTempHealth)
                    gauge("SSD", s.ssdTemp, s.ssdTempHealth)
                    gauge("Battery", s.batteryTemp, s.batteryHealth)
                }
            }
            fans
            battery
        }
    }

    private var rightColumn: some View {
        VStack(spacing: Theme.s3) { memory; storage; network }
    }
    /// Temperature bars share a 20–100 °C scale so the five rows are visually comparable.
    private func gauge(_ name: String, _ v: Double, _ h: Health) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text(name).font(Theme.ui(10)).foregroundStyle(Theme.muted(dark))
                Spacer(minLength: 0)
                Text(Fmt.temp1(v)).font(Theme.number(10, 600)).foregroundStyle(Theme.health(h, dark: dark))
            }
            Bar(value: (v - 20) / 80, color: Theme.healthFill(h, dark: dark), dark: dark)
        }
    }

    // MARK: Fans
    private var fans: some View {
        Group {
            Card(dark: dark, title: "FANS") {
                if s.fans.isEmpty {
                    Text("Fanless design").font(Theme.ui(10)).foregroundStyle(Theme.muted(dark))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 7) {
                        ForEach(s.fans) { f in
                            VStack(spacing: 3) {
                                HStack(spacing: 4) {
                                    Text(f.id).font(Theme.ui(10)).foregroundStyle(Theme.muted(dark))
                                    Spacer(minLength: 0)
                                    Text(f.rpm == 0 ? "idle" : "\(f.rpm) rpm").font(Theme.number(10, 600))
                                }
                                Bar(value: f.ratio, color: Theme.healthFill(Health.grade(f.ratio, warm: 0.45, hot: 0.8), dark: dark), dark: dark)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Battery
    private var battery: some View {
        Group {
            Card(dark: dark, title: "BATTERY") {
                let b = s.battery
                if !b.present {
                    Text("No battery").font(Theme.ui(10)).foregroundStyle(Theme.muted(dark))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 5) {
                        Headline("\(b.percent)%", note: b.isCharging ? "charging" : b.externalPower ? "on power" : "on battery",
                                 color: Theme.health(s.batteryHealth, dark: dark), dark: dark)
                        Bar(value: Double(b.percent) / 100, color: Theme.healthFill(s.batteryHealth, dark: dark), dark: dark)
                        kv("Flow", String(format: "%+.1f W", b.watts))
                        kv("Health", String(format: "%.0f%% · %d cycles", b.health * 100, b.cycles))
                        if let m = b.timeRemainingMin { kv("Remaining", "\(m / 60)h \(m % 60)m") }
                    }
                }
            }
        }
    }

    // MARK: Memory
    private var memory: some View {
        Card(dark: dark, title: "MEMORY") {
            let m = s.memory
            VStack(spacing: 5) {
                Headline(Fmt.gib(m.used), note: "of \(Fmt.gib(m.total))",
                         color: Theme.health(s.memoryHealth, dark: dark), dark: dark)
                StackedBar(parts: [(Double(m.app), Theme.seriesPrimary(dark)),
                                   (Double(m.wired), Theme.series(0, dark)),
                                   (Double(m.compressed), Theme.series(1, dark))],
                           total: Double(m.total), dark: dark)
                kv("App", Fmt.gib(m.app), swatch: Theme.seriesPrimary(dark))
                kv("Wired", Fmt.gib(m.wired), swatch: Theme.series(0, dark))
                kv("Compressed", Fmt.gib(m.compressed), swatch: Theme.series(1, dark))
                kv("Cached", Fmt.gib(m.cached))
                kv("Swap", Fmt.gib(m.swapUsed))
                kv("Pressure", m.pressure >= 75 ? "Normal" : m.pressure >= 45 ? "Elevated" : "Critical",
                   color: Theme.health(s.memoryHealth, dark: dark))
            }
        }
    }

    // MARK: Storage
    private var storage: some View {
        Group {
            Card(dark: dark, title: s.disk.name.isEmpty ? "SSD" : "SSD · \(s.disk.name.uppercased())") {
                let d = s.disk
                VStack(spacing: 5) {
                    Headline(Fmt.bytes(Double(d.total - d.free)), note: "of \(Fmt.bytes(Double(d.total)))",
                             color: Theme.health(s.diskHealth, dark: dark), dark: dark)
                    Bar(value: d.usedRatio, color: Theme.healthFill(s.diskHealth, dark: dark), dark: dark)
                    kv("Read", Fmt.rate(s.diskReadPerSec))
                    kv("Write", Fmt.rate(s.diskWritePerSec))
                    kv("Temp", Fmt.temp1(s.ssdTemp), color: Theme.health(s.ssdTempHealth, dark: dark))
                }
            }
        }
    }

    // MARK: Network
    private var network: some View {
        Group {
            Card(dark: dark, title: s.network.primaryInterface.isEmpty ? "NETWORK"
                                                                     : "NETWORK · \(s.network.primaryInterface.uppercased())") {
                VStack(spacing: 5) {
                    kv("Down", Fmt.rate(s.netInPerSec))
                    kv("Up", Fmt.rate(s.netOutPerSec))
                    if !s.network.primaryAddress.isEmpty { kv("Address", s.network.primaryAddress) }
                    kv("Load", String(format: "%.1f · %.1f · %.1f", s.loadAvg.0, s.loadAvg.1, s.loadAvg.2))
                }
            }
        }
    }

    // MARK: Silicon — per-core activity and where the watts are actually going
    private var silicon: some View {
        let soc = monitor.soc
        let e = soc?.ecpuLabel ?? "E", p = soc?.pcpuLabel ?? "P"
        return Card(dark: dark, title: "\(soc?.chipName.uppercased() ?? "APPLE SILICON") · \(e)\(soc?.ecpuCores ?? 0) + \(p)\(soc?.pcpuCores ?? 0) · GPU \(soc?.gpuCores ?? 0)") {
            VStack(spacing: Theme.s2) {
                HStack(alignment: .bottom, spacing: 3) {
                    if s.cores.isEmpty {
                        Text("Waiting for the first interval…").font(Theme.ui(10)).foregroundStyle(Theme.muted(dark))
                            .frame(height: 28, alignment: .bottom)
                    } else {
                        ForEach(s.cores) { c in
                            CoreBar(ratio: c.scaled, color: c.isP ? Theme.seriesPrimary(dark) : Theme.seriesSecondary(dark), dark: dark)
                                .help("\(c.isP ? p : e) core \(c.core_label) · \(Fmt.ghz(c.freqMHz)) · \(Fmt.pct(c.scaled))")
                        }
                    }
                }
                .frame(height: 30)
                HStack(spacing: Theme.s3) {
                    legend(e, Theme.seriesSecondary(dark), "\(Fmt.ghz(s.ecpuFreq))")
                    legend(p, Theme.seriesPrimary(dark), "\(Fmt.ghz(s.pcpuFreq))")
                    Spacer(minLength: 0)
                }

                Divider().overlay(Theme.stroke(dark)).padding(.vertical, 1)

                // Power rails. The Neural Engine and DRAM figures come from IOReport's energy model
                // and are the part of an Apple Silicon power budget that most monitors never show.
                let rails: [(String, Double, Color)] = [
                    ("CPU", s.cpuPower, Theme.seriesPrimary(dark)),
                    ("GPU", s.gpuPower, Theme.series(0, dark)),
                    ("ANE", s.anePower, Theme.series(1, dark)),
                    ("DRAM", s.ramPower, Theme.series(2, dark)),
                ]
                let railTotal = max(rails.reduce(0) { $0 + $1.1 }, 0.001)
                StackedBar(parts: rails.map { ($0.1, $0.2) }, total: railTotal, dark: dark)
                HStack(spacing: Theme.s3) {
                    ForEach(rails, id: \.0) { rail in
                        legend(rail.0, rail.2, Fmt.watts(rail.1))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func legend(_ title: String, _ color: Color, _ value: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 6, height: 6)
            Text(title).font(Theme.ui(9, 600)).tracking(0.4).foregroundStyle(Theme.muted(dark))
            Text(value).font(Theme.number(9, 500)).foregroundStyle(Theme.ink(dark).opacity(0.75))
        }
    }

    // MARK: Processes — always six rows so the card height never changes between refreshes.
    private var processes: some View {
        Card(dark: dark, title: "TOP PROCESSES") {
            VStack(spacing: 5) {
                ForEach(0..<6, id: \.self) { i in
                    let p = i < s.processes.count ? s.processes[i] : nil
                    HStack(spacing: Theme.s2) {
                        Text(p?.name ?? "—").font(Theme.ui(10)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(p == nil ? Theme.muted(dark) : Theme.ink(dark))
                        Spacer(minLength: 0)
                        Text(p.map { Fmt.bytes(Double($0.memoryBytes)) } ?? "").font(Theme.number(9, 400))
                            .foregroundStyle(Theme.muted(dark)).frame(width: 52, alignment: .trailing)
                        Text(p.map { String(format: "%.1f%%", $0.cpuPercent) } ?? "").font(Theme.number(10, 600))
                            .foregroundStyle(Theme.health(Health.grade(p?.cpuPercent ?? 0, warm: 50, hot: 150), dark: dark))
                            .frame(width: 46, alignment: .trailing)
                    }
                    .frame(height: 13)
                }
            }
        }
    }

    // MARK: All sensors
    @ViewBuilder private var sensors: some View {
        let list = monitor.sensorList
        return Card(dark: dark, title: "ALL SENSORS · \(list.count)") {
            let columns = [GridItem(.flexible(), spacing: Theme.s3), GridItem(.flexible(), spacing: 0)]
            if list.isEmpty {
                Text("Reading…").font(Theme.ui(10)).foregroundStyle(Theme.muted(dark))
            } else {
                // Two hundred–odd rows would dwarf the rest of the dashboard, so the dump scrolls
                // inside its own card and the readings above it stay on screen.
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                        ForEach(list) { x in
                            HStack(spacing: 4) {
                                Text(x.name).font(Theme.ui(8.5)).foregroundStyle(Theme.muted(dark)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(String(format: "%.1f", x.value)).font(Theme.number(8.5, 500))
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: 233)
            }
        }
    }

    private var signature: some View {
        Text("A PARADISE PRODUCTION · 天域文创出品")
            .font(Theme.serif(8.5, 500)).tracking(1.1).foregroundStyle(Theme.muted(dark))
            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 2)
    }

    private func kv(_ k: String, _ v: String, color: Color? = nil, swatch: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let swatch { RoundedRectangle(cornerRadius: 1).fill(swatch).frame(width: 6, height: 6) }
            Text(k).font(Theme.ui(10)).foregroundStyle(Theme.muted(dark))
            Spacer(minLength: 0)
            Text(v).font(Theme.number(10, 500)).foregroundStyle(color ?? Theme.ink(dark))
                .lineLimit(1).minimumScaleFactor(0.75).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Header & controls

private struct BrandHeader: View {
    @ObservedObject var monitor: Monitor
    let dark: Bool
    var body: some View {
        let ch = monitor.channels
        VStack(alignment: .leading, spacing: Theme.s2) {
            // Bottom-aligned, not centred: the wing's ink sits in the lower left of its box and
            // sweeps up to the right, so a vertically centred wordmark leaves a hole under the
            // tip. Setting the text on the root line puts it inside the sweep instead.
            HStack(alignment: .bottom, spacing: Theme.s2) {
                // The mark is the gauge. At this size each feather is thick enough to hold its own
                // colour, so all five channels show — which is the thing the menu bar cannot do.
                WingGaugeView(channels: ch, dark: dark)
                    .frame(width: 55 * BrandMark.aspect, height: 55)   // Fibonacci; below this the innermost feather is too thin to hold a colour
                VStack(alignment: .leading, spacing: 1) {
                    Text("PWE MAC MONITOR").font(Theme.serif(13, 500)).tracking(0.9)
                    Text("\(monitor.soc?.chipName ?? "Apple Silicon") · \(monitor.soc?.memoryGB ?? 0) GB · up \(Fmt.uptime(monitor.snap.uptime))")
                        .font(Theme.ui(9)).tracking(0.2).foregroundStyle(Theme.muted(dark))
                }
                .padding(.bottom, Theme.s1)
                Spacer(minLength: 0)
            }
            ChannelLegend(channels: ch, dark: dark)
        }
        .padding(.horizontal, Theme.s4).padding(.vertical, Theme.s3)
    }
}

/// Names the feathers. Read left to right it runs innermost feather to outermost, so the strip and
/// the mark above it are the same five readings in the same order — one is the picture, the other
/// the key. A calm channel stays uncoloured here exactly as it does everywhere else.
private struct ChannelLegend: View {
    let channels: [ChannelHealth]
    let dark: Bool
    var body: some View {
        HStack(spacing: Theme.s1) {
            ForEach(channels, id: \.channel) { c in
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.channel.label)
                        .font(Theme.ui(8, 600)).tracking(1.2)
                        .foregroundStyle(c.band == .calm ? Theme.muted(dark) : Theme.health(c.band, dark: dark))
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.rail(dark))
                            Capsule().fill(Theme.healthFill(c.band, dark: dark))
                                .frame(width: max(2, g.size.width * c.fill))
                        }
                    }
                    .frame(height: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ControlBar: View {
    @ObservedObject var monitor: Monitor
    let dark: Bool
    var body: some View {
        HStack(spacing: Theme.s2) {
            Text("EVERY").font(Theme.ui(8.5, 600)).tracking(1.4).foregroundStyle(Theme.muted(dark))
            ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { v in
                let on = monitor.interval == v
                Button { monitor.interval = v } label: {
                    Text("\(Int(v))s").font(Theme.number(10, on ? 600 : 400))
                        .foregroundStyle(on ? Theme.accent(dark) : Theme.muted(dark))
                        .frame(width: 27, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(on ? Theme.accent(dark).opacity(dark ? 0.18 : 0.14) : Theme.ink(dark).opacity(0.001)))
                        // A clear fill is not hit-tested by SwiftUI, so the whole chip needs an
                        // explicit content shape or only the glyphs themselves would be clickable.
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()          // no system blue focus ring inside the popover
                .help("Refresh every \(Int(v)) second\(v == 1 ? "" : "s")")
            }
            Spacer(minLength: 0)
            SettingsButton(dark: dark) { view in monitor.presentMenu?(view) }
        }
        .padding(.horizontal, Theme.s4).padding(.vertical, Theme.s2)
    }
}

// MARK: - Components

/// The settings affordance. AppKit rather than SwiftUI's `Menu`, which insists on drawing a system
/// focus ring inside the popover and cannot be talked out of it; this also means the gear and the
/// status item's right-click menu are literally the same menu.
struct SettingsButton: NSViewRepresentable {
    let dark: Bool
    let present: (NSView) -> Void

    func makeNSView(context: Context) -> ButtonView {
        let v = ButtonView(frame: NSRect(x: 0, y: 0, width: 26, height: 20))
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        v.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(config)
        v.image?.isTemplate = true
        v.isBordered = false
        v.bezelStyle = .inline
        v.focusRingType = .none
        v.imagePosition = .imageOnly
        v.title = ""
        v.toolTip = "Settings"
        v.present = present
        return v
    }
    func updateNSView(_ v: ButtonView, context: Context) {
        v.present = present
        v.contentTintColor = NSColor(Theme.muted(dark))
    }

    final class ButtonView: NSButton {
        var present: ((NSView) -> Void)?
        override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 20) }
        override var acceptsFirstResponder: Bool { false }
        override func mouseDown(with event: NSEvent) { present?(self) }
    }
}

/// The mark as a live gauge, for the panel. `WingMark` remains the identity form.
struct WingGaugeView: NSViewRepresentable {
    let channels: [ChannelHealth]
    let dark: Bool
    func makeNSView(context: Context) -> GaugeView { GaugeView() }
    func updateNSView(_ v: GaugeView, context: Context) {
        v.channels = channels; v.dark = dark; v.needsDisplay = true
    }
    final class GaugeView: NSView {
        var channels: [ChannelHealth] = []
        var dark = true
        override func draw(_ dirtyRect: NSRect) {
            WingGauge.draw(channels, in: bounds, calmInk: NSColor(Theme.ink(dark)),
                           dark: dark, perFeather: true)
        }
    }
}

struct WingMark: NSViewRepresentable {
    let color: Color
    func makeNSView(context: Context) -> WingView { WingView() }
    func updateNSView(_ v: WingView, context: Context) { v.color = NSColor(color); v.needsDisplay = true }
    final class WingView: NSView {
        var color: NSColor = .labelColor
        override func draw(_ dirtyRect: NSRect) { BrandMark.draw(in: bounds, color: color) }
    }
}

struct Card<Content: View>: View {
    let dark: Bool
    var title: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            if let title { SectionLabel(title, dark: dark) }
            content
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card(dark)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.stroke(dark), lineWidth: 1))
    }
}

/// Small-caps section label — Inter Semibold with the brand's +0.18em tracking (standard section 6).
struct SectionLabel: View {
    let text: String, dark: Bool
    var ruled = true
    init(_ text: String, dark: Bool, ruled: Bool = true) { self.text = text; self.dark = dark; self.ruled = ruled }
    var body: some View {
        HStack(spacing: Theme.s2) {
            Text(text).font(Theme.ui(8.5, 600)).tracking(1.5).foregroundStyle(Theme.muted(dark))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            if ruled { Rectangle().fill(Theme.stroke(dark)).frame(height: 1) }
        }
    }
}

struct Headline: View {
    let value: String, note: String, color: Color, dark: Bool
    init(_ value: String, note: String, color: Color, dark: Bool) {
        self.value = value; self.note = note; self.color = color; self.dark = dark
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(Theme.number(17, 600)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(Theme.ui(8.5)).foregroundStyle(Theme.muted(dark)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

struct Bar: View {
    let value: Double, color: Color, dark: Bool
    var body: some View {
        GeometryReader { g in
            let filled = g.size.width * min(1, max(0, value))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.rail(dark))
                if filled > 0.5 { Capsule().fill(color).frame(width: max(3, filled)) }
            }
        }
        .frame(height: 4)
    }
}

struct StackedBar: View {
    let parts: [(Double, Color)], total: Double, dark: Bool
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Rectangle().fill(p.1).frame(width: max(0, g.size.width * zeroDiv(p.0, total)))
                }
                Spacer(minLength: 0)
            }
            .background(Theme.rail(dark))
            .clipShape(Capsule())
        }
        .frame(height: 5)
    }
}

/// One CPU core column. Fixed geometry — no GeometryReader — so a row of sixteen stays cheap.
struct CoreBar: View {
    let ratio: Double, color: Color, dark: Bool
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.rail(dark).opacity(0.7))
            let filled = 28 * min(1, max(0, ratio))
            if filled > 0.5 { RoundedRectangle(cornerRadius: 2).fill(color).frame(height: max(2, filled)) }
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
    }
}

struct Sparkline: View {
    let values: [Double]
    let ceiling: Double?
    let color: Color
    var body: some View {
        GeometryReader { g in
            let n = CGFloat(Theme.historyLength - 1)
            let top = ceiling ?? Swift.max(values.max() ?? 1, 0.001)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i + Theme.historyLength - values.count) / n,
                        y: g.size.height * (1 - CGFloat(Swift.min(1, Swift.max(0, v / top)))))
            }
            Path { p in
                p.move(to: CGPoint(x: 0, y: g.size.height - 0.5))
                p.addLine(to: CGPoint(x: g.size.width, y: g.size.height - 0.5))
            }
            .stroke(color.opacity(0.18), lineWidth: 1)
            if pts.count > 1 {
                Path { p in
                    p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.30), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    p.move(to: pts[0])
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
