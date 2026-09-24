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
    ///
    /// The two opacities are not the same number because the two grounds are not equally kind to
    /// them: navy ink at 34 % on white measured 2.17:1, against 3.73:1 for paper at 42 % on the
    /// dark card — the light theme was showing its calm readings at half the contrast of the dark
    /// one. 46 % brings it to 3.04:1, over the 3:1 floor for a graphical object that carries
    /// meaning, which the filled part of a bar does.
    static func healthFill(_ h: Health, dark: Bool) -> Color {
        h == .calm ? ink(dark).opacity(dark ? 0.42 : 0.46) : health(h, dark: dark)
    }

    /// Series colours for composition bars (core clusters, memory segments, power rails): a
    /// neutral ink ramp, and nothing else.
    ///
    /// Until 1.5.0 the leading series was drawn in `accent` — which is the very same value as
    /// `health(.warm)`. The comment said "identity, not status", but a colour cannot carry a
    /// footnote: an idle Mac showed amber on every P-core, on the memory App segment and on
    /// whichever power rail happened to lead, at 0.2 W as much as at 90. Status is the only thing
    /// amber may say. A segment that is under load takes the status colour from its own reading;
    /// the rest of the time it is ink.
    ///
    /// Four steps because the power rail has four segments. Measured against the bar's own
    /// track, the lightest clears 1.53:1 light / 2.01:1 dark — the old three-step ramp's
    /// lightest was 1.37:1, and every step here is darker than the one it replaces.
    static func series(_ step: Int, _ dark: Bool) -> Color {
        let opacity = [0.70, 0.52, 0.36, 0.24][min(max(step, 0), 3)]
        return ink(dark).opacity(dark ? opacity : opacity * 0.85)
    }
    static func healthNS(_ h: Health, dark: Bool) -> NSColor { NSColor(health(h, dark: dark)) }

    // MARK: Type — the platform's own face, at the platform's own sizes.
    //
    // Until 1.3.0 this shipped Inter and Playfair Display inside the bundle and drew the whole
    // interface in them. Three things were wrong with that, and the third is decisive:
    //
    //   · SF Pro changes shape with size (Text below 20 pt, Display above) and carries Apple's
    //     own tracking tables. A single static face gets that wrong at both ends.
    //   · A bundled face does not participate in the reader's text-size setting.
    //   · **Inter has no CJK glyphs.** Every Chinese string in this bilingual app was already
    //     being drawn by the system's fallback — so the "brand face" only ever reached half the
    //     readers, and the half it missed got no weight matching from the `wght` axis either.
    //     Asking for the system font gets PingFang matched to SF Pro's weights, which is the
    //     behaviour the brand standard §7.2 spent a page describing and could not implement.
    //
    // Planning doc 17 §4.2. Playfair survives in one place only, and it is not this app: the
    // Paradise Production seal on the film line.
    private static func face(_ size: CGFloat, _ weight: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: nsWeight(weight))
    }

    /// The 100–900 numbers the call sites use, mapped onto the platform's named weights.
    private static func nsWeight(_ weight: CGFloat) -> NSFont.Weight {
        switch weight {
        case ..<350:  return .light
        case ..<450:  return .regular
        case ..<550:  return .medium
        case ..<650:  return .semibold
        default:      return .bold
        }
    }

    /// The wordmark and anything that speaks as the product rather than as a readout.
    ///
    /// Named for its job, not its face. It used to be Playfair Display and the name `serif` said
    /// so; a helper whose name describes the file it loads is a helper that lies the moment the
    /// file changes.
    static func wordmark(_ size: CGFloat, _ weight: CGFloat = 600) -> Font {
        Font(face(size, weight))
    }

    /// All interface text.
    static func ui(_ size: CGFloat, _ weight: CGFloat = 400) -> Font { Font(face(size, weight)) }

    /// Tabular figures, for anything that changes every refresh. A digit that changes width
    /// makes the column beside it jump, which reads as the number being unstable rather than the
    /// layout.
    static func number(_ size: CGFloat, _ weight: CGFloat = 500) -> Font {
        Font(NSFont.monospacedDigitSystemFont(ofSize: size, weight: nsWeight(weight)))
    }

    /// Small-caps section label, and the one place the identity standard needs an exception.
    ///
    /// Standard §6 sets Semibold at +0.18em tracking, which is a rule about Latin small caps:
    /// Han has no small caps, and letterspacing it at that ratio reads as a defect rather than
    /// as emphasis. 8.5 pt is also below what Apple ships as "mini" — tolerable for Latin caps
    /// and not for PingFang. Recorded as §7.2 衍生字体例外.
    static func label(_ size: CGFloat = 8.5) -> Font { ui(Loc.isCJK ? size + 1 : size, 600) }
    static func labelTracking(_ t: CGFloat) -> CGFloat { Loc.isCJK ? t * 0.4 : t }

    /// The menu-bar glyph's figures. Drawn with AppKit rather than SwiftUI, so it needs the
    /// `NSFont` rather than the `Font`.
    static func nsNumber(_ size: CGFloat, _ weight: CGFloat = 500) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: nsWeight(weight))
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
        if d > 0 { return String(format: L("fmt.uptime.dh", "%1$dd %2$dh"), d, h) }
        if h > 0 { return String(format: L("fmt.uptime.hm", "%1$dh %2$dm"), h, m) }
        return String(format: L("fmt.uptime.m", "%dm"), m)
    }
    /// The sparkline window, stated on the card rather than only in a tooltip — it moves with the
    /// refresh interval, so it is not something the reader can learn once.
    static func window(_ seconds: Double) -> String {
        seconds < 90 ? String(format: L("fmt.window.sec", "last %ds"), Int(seconds.rounded()))
                     : String(format: L("fmt.window.min", "last %d min"), Int((seconds / 60).rounded()))
    }
}
