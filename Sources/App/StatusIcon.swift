import AppKit

/// The menu-bar glyph, drawn as a vector NSImage so it stays crisp at any scale factor.
///
/// Brand rule (standard section 7): the wing is never recoloured outside navy / amber / deep amber /
/// white / black. In the menu bar it therefore renders in the bar's own label colour, and the health
/// state is carried by a separate element — the rule beneath it — plus the coloured readouts.
enum StatusIcon {
    static let height: CGFloat = 22
    private static let wingHeight: CGFloat = 10.0   // 16.2 pt wide — the standard's 24 px minimum at 2x
    private static var wingWidth: CGFloat { wingHeight * BrandMark.aspect }

    static func render(_ s: Snapshot, overall: Health, powerHealth: Health, mode: MenuBarMode, dark: Bool) -> NSImage {
        let label: NSColor = dark ? .white : .black
        let state = Theme.healthNS(overall, dark: dark)
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
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Wing mark, in the label colour, sitting above its status rule.
            let wingBox = CGRect(x: lead, y: rect.midY - wingHeight / 2 + 1.5, width: wingWidth, height: wingHeight)
            BrandMark.draw(in: wingBox, color: label)

            // Status rule: full width is the mark, filled portion is CPU load, colour is overall health.
            let ruleY = wingBox.minY - 3, ruleH: CGFloat = 2
            let track = CGRect(x: wingBox.minX, y: ruleY, width: wingWidth, height: ruleH)
            ctx.setFillColor(label.withAlphaComponent(0.20).cgColor)
            ctx.fill(track)
            let fill = CGRect(x: track.minX, y: ruleY, width: max(2, wingWidth * min(1, max(0.03, s.cpuUsage))), height: ruleH)
            ctx.setFillColor(state.cgColor)
            ctx.fill(fill)

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
