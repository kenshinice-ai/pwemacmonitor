import AppKit

/// The menu-bar glyph, drawn as a vector NSImage so it stays crisp at any scale factor.
///
/// The mark itself is the gauge (brand standard §7.1): colour travels out along the feathers as the
/// machine approaches trouble, so the separate status rule this glyph used to carry is gone — the
/// wing now says what the rule said, in the space the wing already occupied.
///
/// One colour only, not five. A 22 pt bar leaves each feather about 1 pt thick, and a real-size
/// prototype showed five tints there collapse into a mottled smear that reports "something" without
/// reporting what. Per-feather detail lives in the panel; see `docs/wing-states.md`.
enum StatusIcon {
    static let height: CGFloat = 22
    private static let wingHeight: CGFloat = 11.5   // 18.6 pt wide — the standard's 24 px minimum at 2x
    private static var wingWidth: CGFloat { wingHeight * BrandMark.aspect }

    static func render(_ s: Snapshot, channels: [ChannelHealth], overall: Health,
                       powerHealth: Health, mode: MenuBarMode, dark: Bool) -> NSImage {
        let label: NSColor = dark ? .white : .black
        let font = Theme.nsNumber(11.5, 500)

        var segments: [(String, NSColor)] = []
        switch mode {
        case .icon: break
        case .compact:
            segments = [(Fmt.watts(s.sysPower), label), (Fmt.temp(s.cpuTempMax), Theme.healthNS(s.cpuTempMaxHealth, dark: dark))]
        case .full:
            segments = [(Fmt.pct(s.cpuUsage), label),
                        (Fmt.watts(s.sysPower), Theme.healthNS(powerHealth, dark: dark)),
                        (Fmt.temp(s.cpuTempMax), Theme.healthNS(s.cpuTempMaxHealth, dark: dark))]
        }

        let gap: CGFloat = 6, lead: CGFloat = 3, trail: CGFloat = 2
        let widths = segments.map { ($0.0 as NSString).size(withAttributes: [.font: font]).width }
        let textRun = widths.reduce(0, +) + CGFloat(max(segments.count - 1, 0)) * gap
        let width = lead + wingWidth + (segments.isEmpty ? 0 : gap + textRun) + trail

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { rect in
            // The mark, drawn as the gauge — cached on a quantised reading, which matters most
            // in hot, where the halo is the expensive part. See WingGauge's cache note.
            let wingBox = CGRect(x: lead, y: rect.midY - wingHeight / 2, width: wingWidth, height: wingHeight)
            WingGauge.barImage(channels, size: wingBox.size, calmInk: label, dark: dark).draw(in: wingBox)

            var x = lead + wingWidth + gap
            for (i, seg) in segments.enumerated() {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: seg.1]
                let str = seg.0 as NSString
                let h = str.size(withAttributes: attrs).height
                str.draw(at: NSPoint(x: x, y: (height - h) / 2), withAttributes: attrs)
                x += widths[i] + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
