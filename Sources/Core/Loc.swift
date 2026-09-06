import Foundation

/// Interface language.
///
/// `.system` follows the Mac, which is the right default and the only behaviour most apps offer.
/// It is not enough on its own here: a great many Chinese speakers run macOS in English on
/// purpose, and following the system would mean they never see the Chinese build at all. The two
/// explicit cases override it.
enum Language: String, CaseIterable {
    case system, en, zhHans = "zh-Hans"

    /// Endonyms — a language is named in itself, never translated. Someone looking for Chinese in
    /// an English interface is looking for the characters, not for the word "Chinese".
    var label: String {
        switch self {
        case .system: return L("lang.system", "Follow System")
        case .en:     return "English"
        case .zhHans: return "简体中文"
        }
    }
}

/// Looks a string up in the bundled `.lproj` tables.
///
/// The English text lives at the call site rather than in a table, which buys two things: English
/// can never go missing however badly the tables drift, and `en.lproj` becomes a generated file —
/// `Tools/loccheck` writes it from the sources, so only `zh-Hans.lproj` is maintained by hand and
/// drift is possible in one direction only.
///
/// Foundation-only on purpose. `Sources/Core` is also compiled into `Tools/thresholds`,
/// `Tools/icon` and `Tools/bench`, which have no bundle at all; there `resolve()` returns nil and
/// every lookup falls through to the English default.
enum Loc {
    static let supported = ["en", "zh-Hans"]

    static var language: Language = .system {
        didSet { guard language != oldValue else { return }; bundle = resolve() }
    }
    private static var bundle: Bundle? = resolve()

    /// The language actually in force, with `.system` already resolved against the Mac's settings.
    static var effective: String {
        switch language {
        case .system: return Bundle.preferredLocalizations(from: supported).first ?? "en"
        case .en:     return "en"
        case .zhHans: return "zh-Hans"
        }
    }

    /// True when the interface is being drawn in a Han script. Type needs an exception there —
    /// see `Theme.ui` — so this is read by the typography layer, not just by the string lookup.
    static var isCJK: Bool { effective.hasPrefix("zh") }

    private static func resolve() -> Bundle? {
        guard let p = Bundle.main.path(forResource: effective, ofType: "lproj") else { return nil }
        return Bundle(path: p)
    }

    static func string(_ key: String, _ english: String) -> String {
        guard let b = bundle else { return english }
        // `value:` is the miss sentinel, so a key absent from the table yields the English written
        // at the call site rather than the key itself.
        let v = b.localizedString(forKey: key, value: "\u{0}", table: nil)
        return v == "\u{0}" ? english : v
    }
}

/// `L("card.thermals", "THERMALS")` — key first, English second.
///
/// Returns a plain `String`, never a `LocalizedStringKey`. That matters: SwiftUI's `Text`,
/// `.help` and `.accessibilityLabel` all take `LocalizedStringKey`, so a bare literal in any of
/// them would be looked up a second time against `Bundle.main` — which follows the *system*
/// language and would quietly ignore an in-app override. Routing every piece of copy through a
/// `String` is what keeps the override honest.
func L(_ key: String, _ english: String) -> String { Loc.string(key, english) }
