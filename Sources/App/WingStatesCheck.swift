import AppKit

/// `pwemon --wing-states DIR` — renders the mark's three states through the real renderer.
///
/// The machine under the developer's hands is almost always calm, so warm and hot would otherwise
/// go unlooked-at until a user hit them. This drives `WingGauge` and `StatusIcon` with synthetic
/// channel readings instead, at menu-bar size and panel size, in both appearances. It is the check
/// that decided per-feather colour cannot work at 22 pt; re-run it after touching either file.
enum WingStatesCheck {

    private static func scene(_ name: String) -> (String, [ChannelHealth], Snapshot) {
        var s = Snapshot()
        let mk: (Channel, Health, Double) -> ChannelHealth = { ChannelHealth(channel: $0, band: $1, fill: $2) }
        switch name {
        case "warm":
            s.cpuUsage = 0.61; s.sysPower = 38.4; s.cpuTempMax = 79
            return (name, [mk(.memory, .calm, 0.30), mk(.ssd, .calm, 0.42), mk(.power, .warm, 0.79),
                           mk(.gpu, .warm, 0.83), mk(.cpu, .warm, 0.88)], s)
        case "hot":
            s.cpuUsage = 0.94; s.sysPower = 82.1; s.cpuTempMax = 88
            return (name, [mk(.memory, .calm, 0.34), mk(.ssd, .calm, 0.46), mk(.power, .hot, 1.00),
                           mk(.gpu, .hot, 1.00), mk(.cpu, .warm, 0.93)], s)
        default:
            s.cpuUsage = 0.09; s.sysPower = 9.5; s.cpuTempMax = 54
            return (name, [mk(.memory, .calm, 0.24), mk(.ssd, .calm, 0.31), mk(.power, .calm, 0.28),
                           mk(.gpu, .calm, 0.22), mk(.cpu, .calm, 0.52)], s)
        }
    }

    /// `pwemon --bench-icon` — the redraw cost of the menu-bar glyph, which is the one thing the
    /// gauge made more expensive: a flat fill became five clipped gradients plus, in hot, a blur.
    /// Reports cold (cache miss) and warm (hit) separately, because the bar only ever pays cold
    /// when a reading actually moves past a 5 % step.
    static func bench() {
        let (_, channels, snap) = scene("warm")
        let (_, hotCh, hotSnap) = scene("hot")
        // NSImage's drawing handler is lazy: it does not run until something rasterises the
        // image. Timing `render` alone measures allocation and nothing else — force the pixels.
        func time(_ label: String, _ n: Int, _ body: () -> NSImage) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<n { _ = body().tiffRepresentation }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(n)
            let pad = label.padding(toLength: 34, withPad: " ", startingAt: 0)
            print("  " + pad + String(format: "%7.3f ms", ms))
        }
        print("menu-bar glyph redraw cost (rasterised)")
        var jitter = 0.0
        time("cold — every reading moved", 200) {
            jitter += 0.051
            let moved = channels.map { ChannelHealth(channel: $0.channel, band: $0.band,
                                                     fill: ($0.fill + jitter).truncatingRemainder(dividingBy: 1)) }
            return StatusIcon.render(snap, channels: moved, overall: .warm, powerHealth: .warm, mode: .full, dark: true)
        }
        time("warm — reading unchanged (the norm)", 2000) {
            StatusIcon.render(snap, channels: channels, overall: .warm, powerHealth: .warm, mode: .full, dark: true)
        }
        time("hot — cold, with the halo", 200) {
            jitter += 0.051
            let moved = hotCh.map { ChannelHealth(channel: $0.channel, band: $0.band,
                                                  fill: ($0.fill + jitter).truncatingRemainder(dividingBy: 1)) }
            return StatusIcon.render(hotSnap, channels: moved, overall: .hot, powerHealth: .hot, mode: .full, dark: true)
        }
        print("  a sample lands every 1–5 s, so cold is the worst case, not the common one")
    }

    static func write(to dir: String) {
        let scenes = ["calm", "warm", "hot"].map(scene)
        let panelH: CGFloat = 55, panelW = panelH * BrandMark.aspect
        let zoom: CGFloat = 3
        let rowH = panelH * zoom + 26
        let sheet = NSSize(width: 890, height: rowH * CGFloat(scenes.count) + 46)

        for dark in [true, false] {
            let ink = NSColor(Theme.ink(dark))
            let ground = dark ? NSColor(Theme.background(dark)) : NSColor(Theme.background(dark))
            let barGround = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.96, alpha: 1)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(sheet.width * 2), pixelsHigh: Int(sheet.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = sheet
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            ground.setFill(); NSBezierPath(rect: CGRect(origin: .zero, size: sheet)).fill()

            func text(_ t: String, _ p: CGPoint, _ size: CGFloat, _ c: NSColor) {
                (t as NSString).draw(at: p, withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold), .foregroundColor: c])
            }
            text("wing states · \(dark ? "dark" : "light") · menu bar 22 pt (1x, 4x) · panel \(Int(panelH)) pt (1x, \(Int(zoom))x)",
                 CGPoint(x: 21, y: sheet.height - 24), 9, ink.withAlphaComponent(0.7))

            var y = sheet.height - 46
            for (name, channels, snap) in scenes {
                text(name.uppercased(), CGPoint(x: 21, y: y - 14), 9, ink.withAlphaComponent(0.55))
                // menu bar, through the shipping glyph
                let glyph = StatusIcon.render(snap, channels: channels,
                                              overall: channels.map(\.band).max() ?? .calm,
                                              powerHealth: channels[Channel.power.rawValue].band,
                                              mode: .full, dark: dark)
                let iconOnly = StatusIcon.render(snap, channels: channels,
                                                 overall: channels.map(\.band).max() ?? .calm,
                                                 powerHealth: channels[Channel.power.rawValue].band,
                                                 mode: .icon, dark: dark)
                var x: CGFloat = 72
                for (img, s) in [(glyph, CGFloat(1)), (iconOnly, 4)] {
                    let box = CGRect(x: x, y: y - StatusIcon.height * s, width: img.size.width * s,
                                     height: StatusIcon.height * s)
                    barGround.setFill(); NSBezierPath(rect: box).fill()
                    img.draw(in: box)
                    x += box.width + 18
                }
                // panel, through the same gauge the header uses
                for s in [CGFloat(1), zoom] {
                    let box = CGRect(x: x, y: y - panelH * s, width: panelW * s, height: panelH * s)
                    WingGauge.draw(channels, in: box, calmInk: ink, dark: dark, perFeather: true)
                    x += box.width + 16
                }
                y -= rowH
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/wing-states-\(dark ? "dark" : "light").png"))
        }
        print("wrote wing-states-{dark,light}.png to \(dir)")
    }
}
