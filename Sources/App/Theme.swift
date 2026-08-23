import SwiftUI
import AppKit
import CoreText

/// Paradise Production brand tokens (identity standard v1.0, section 5–6) plus the golden-ratio
/// spacing scale the whole interface is laid out on.
enum Theme {

    // MARK: Spacing — Fibonacci, the integer approximation of φ
    static let s1: CGFloat = 5, s2: CGFloat = 8, s3: CGFloat = 13, s4: CGFloat = 21, s5: CGFloat = 34
    static let width: CGFloat = 377          // Fibonacci
    static let historyLength = 89            // Fibonacci
    static let radius: CGFloat = 8

    // MARK: Brand palette (section 5 — these HEX values are normative)
    static let navy = Color(hex: 0x0E1729)
    static let amber = Color(hex: 0xF5B335)          // dark backgrounds only
    static let amberDeep = Color(hex: 0xA16207)      // light backgrounds
    static let paper = Color(hex: 0xF7F5F2)
    static let line = Color(hex: 0xE3DFD8)
    static let mutedInk = Color(hex: 0x6B7280)

    /// Alert colour — the one hue outside the brand palette, reserved for a genuine problem.
    /// Nothing else in the interface is allowed to use it.
    static let coral = Color(hex: 0xE8654E), coralDeep = Color(hex: 0xB03A24)

    // MARK: Surfaces
    static func background(_ dark: Bool) -> Color { dark ? navy : paper }
    static func card(_ dark: Bool) -> Color { dark ? Color(hex: 0x152239) : .white }
    static func stroke(_ dark: Bool) -> Color { dark ? Color.white.opacity(0.07) : line }
    static func rail(_ dark: Bool) -> Color { dark ? Color.white.opacity(0.10) : Color(hex: 0xEDEAE4) }
    static func ink(_ dark: Bool) -> Color { dark ? paper : navy }
    static func muted(_ dark: Bool) -> Color { dark ? paper.opacity(0.52) : mutedInk }
    static func accent(_ dark: Bool) -> Color { dark ? amber : amberDeep }

    /// Status colour. A calm reading is deliberately *not* coloured — it renders in the normal
    /// text ink, so colour in this interface always means "look at me". Warm is the brand amber,
    /// hot is the alert coral. (The brand palette contains no green; a green-for-normal scheme
    /// would both break the identity and spend the reader's attention on nothing.)
    static func health(_ h: Health, dark: Bool) -> Color {
        switch h {
        case .calm: return ink(dark)
        case .warm: return dark ? amber : amberDeep
        case .hot:  return dark ? coral : coralDeep
        }
    }

    /// Fill colour for a bar or gauge track. Calm fills stay quiet rather than disappearing.
    static func healthFill(_ h: Health, dark: Bool) -> Color {
        h == .calm ? ink(dark).opacity(dark ? 0.42 : 0.34) : health(h, dark: dark)
    }

    /// Series colours for composition bars (core clusters, memory segments, power rails).
    /// Identity, not status: amber marks the leading series and everything else steps down a
    /// neutral ink ramp. Coral never appears here — it means "a problem" everywhere else in the
    /// interface, and a stacked bar segment is not a problem.
    static func seriesPrimary(_ dark: Bool) -> Color { accent(dark) }
    static func series(_ step: Int, _ dark: Bool) -> Color {
        let opacity = [0.50, 0.32, 0.18][min(max(step, 0), 2)]
        return ink(dark).opacity(dark ? opacity : opacity * 0.85)
    }
    static func seriesSecondary(_ dark: Bool) -> Color { series(0, dark) }
    static func healthNS(_ h: Health, dark: Bool) -> NSColor { NSColor(health(h, dark: dark)) }

    // MARK: Type (section 6) — Playfair Display for the brand voice, Inter for the interface.
    // Both ship inside the bundle as variable fonts, so the app never depends on installed fonts.
    private static func variable(_ family: String, size: CGFloat, weight: CGFloat, fallback: NSFont) -> NSFont {
        let wght = 0x77676874 as CFNumber   // 'wght'
        let desc = NSFontDescriptor(fontAttributes: [
            .family: family,
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): [wght: weight],
        ])
        return NSFont(descriptor: desc, size: size) ?? fallback
    }

    /// Playfair Display — headings and the wordmark.
    static func serif(_ size: CGFloat, _ weight: CGFloat = 500) -> Font {
        Font(variable("Playfair Display", size: size, weight: weight,
                      fallback: .systemFont(ofSize: size, weight: .medium)))
    }
    /// Inter — all interface text.
    static func ui(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        Font(variable("Inter", size: size, weight: weight,
                      fallback: .systemFont(ofSize: size, weight: weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular)))
    }
    /// Inter with tabular figures, for anything that changes every refresh.
    static func number(_ size: CGFloat, _ weight: CGFloat = 500) -> Font {
        let base = variable("Inter", size: size, weight: weight, fallback: .monospacedDigitSystemFont(ofSize: size, weight: .medium))
        let desc = base.fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]],
        ])
        return Font(NSFont(descriptor: desc, size: size) ?? base)
    }
    static func nsNumber(_ size: CGFloat, _ weight: CGFloat = 500) -> NSFont {
        let base = variable("Inter", size: size, weight: weight, fallback: .monospacedDigitSystemFont(ofSize: size, weight: .medium))
        let desc = base.fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]],
        ])
        return NSFont(descriptor: desc, size: size) ?? base
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

enum Fmt {
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    static func watts(_ v: Double) -> String { v >= 10 ? String(format: "%.0f W", v) : String(format: "%.1f W", v) }
    static func temp(_ v: Double) -> String { v > 0 ? String(format: "%.0f°", v) : "—" }
    static func temp1(_ v: Double) -> String { v > 0 ? String(format: "%.1f°C", v) : "—" }
    static func ghz(_ mhz: Int) -> String { mhz > 0 ? String(format: "%.2f GHz", Double(mhz) / 1000) : "—" }
    static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return String(format: v >= 100 || i == 0 ? "%.0f %@" : "%.1f %@", v, units[i])
    }
    static func gib(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
    static func rate(_ bps: Double) -> String { bytes(bps) + "/s" }
    static func uptime(_ t: TimeInterval) -> String {
        let d = Int(t) / 86400, h = (Int(t) % 86400) / 3600, m = (Int(t) % 3600) / 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
