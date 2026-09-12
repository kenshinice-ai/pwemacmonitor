# Localisation

English and 简体中文, in an app with no Xcode project. Added in v1.2.0.

## How it works

`Sources/Core/Loc.swift` is the whole mechanism, and it is Foundation-only — `Sources/Core` is also
compiled into `Tools/thresholds`, `Tools/icon` and `Tools/bench`, which have no bundle at all.

```swift
L("card.thermals", "THERMALS")      // key first, English second
```

**The English lives at the call site, not in a table.** That buys two things: English cannot go
missing however badly the tables drift, and `Resources/en.lproj` becomes a *generated* file —
`Tools/loccheck` writes it from the sources. `Resources/zh-Hans.lproj/Localizable.strings` is the
only table maintained by hand, so drift is possible in one direction only.

`build.sh` runs `loccheck` before it assembles the bundle. It fails the build on:

- a key used in `Sources/` but absent from `zh-Hans.lproj`
- a key in `zh-Hans.lproj` no longer used anywhere
- one key given two different English texts

A missing key would otherwise surface as a single English row inside an otherwise Chinese panel —
the kind of defect that survives a demo and ships.

### Adding a language

1. `Resources/<code>.lproj/Localizable.strings`, copied from the generated `en.lproj`.
2. Add the code to `Loc.supported` and a case to `Language`.
3. Add it to `CFBundleLocalizations` in `Resources/Info.plist`.
4. Teach `loccheck` to check it — currently it checks `zh-Hans` by name.

`.strings` files are plain UTF-8 here. There is no compilation step: Foundation reads the old-style
property-list format straight off disk, so `build.sh` only has to `ditto` the `.lproj` directories
into `Contents/Resources`.

## Choosing the language

`.system` follows the Mac and is the default. **Language** in the settings menu overrides it,
because a great many Chinese speakers run macOS in English on purpose and following the system
would mean they never saw the Chinese build at all.

For rendering either language without touching your own setting — `-language` is read from
`UserDefaults`' argument domain:

```bash
"build/PWE Monitor.app/Contents/MacOS/pwemon" --snapshot docs --demo -language zh-Hans
```

## Three traps

**1. `Text("literal")` is a `LocalizedStringKey`.** So are `.help()` and `.accessibilityLabel()`.
The moment a bundle contains `.lproj` directories, SwiftUI starts looking every bare literal up in
`Bundle.main` using the string itself as the key — and `Bundle.main` follows the *system* language,
which would quietly ignore the in-app override. Every piece of copy therefore goes through `L()`,
which returns a plain `String`; SwiftUI does not localise those.

**2. Sentences built by concatenation do not survive translation.** The VoiceOver line was

```swift
list.joined(separator: ". ") + ". The rest calm."
```

with English punctuation and clause order baked into the structure. The joiner and the closing
clause are now table entries of their own (`a11y.joiner`, `a11y.restCalm`), so Chinese can use `、`
and `。其余平稳。` instead. Every format string is positional (`%1$@`), so a language that needs a
different argument order can have one.

**3. `Sources/Core` has no bundle in the Tools.** `Loc.string` returns the call-site English when
`Bundle.main.path(forResource:ofType:)` finds nothing, which is what makes `Tools/thresholds` still
build and run.

## What is never translated

The wordmark · the five channel keys `MEM SSD PWR GPU CPU`, which `wing-states.md` defines the
channels by · the power rails `CPU GPU ANE DRAM` · the core cluster labels `E` and `P` · units ·
SMC sensor names · process names · **everything `--probe` and `--json` print**, which is a machine
interface that scripts parse.

`--demo` process names and the diagnostics on the clipboard are English too: a bug report is easier
to act on in the same form the CLI and the JSON already use.

## Typography

**No Chinese font is bundled.** Measured 2026-09-02: Core Text cascades to PingFang SC on its own
and matches the weight — `Inter` at 600 falls to `PingFangSC-Semibold`, `Playfair Display` at 500 to
`PingFangSC-Medium`. In a mixed run the digits stay in Inter, so the tabular-figures feature that
every changing number depends on is preserved:

```
"已压缩 4.2 GB"   runs: PingFangSC-Regular×3 + Inter-Regular×7
```

Two measurements that shaped the layout work:

| | Latin | Han |
|---|---|---|
| Width, same point size | `THERMALS` 59.0 pt | `温度` 20.0 pt |
| Line height at 8.5 pt | asc 8.23 / desc 2.05 | asc 9.01 / desc 2.89 |

Chinese is about **half the width** and **16 % taller per line**. A fixed-width layout is therefore
not at risk from it; a fixed-height one is. The panel measures 1070 pt in English and 1076 pt in
Chinese, both stable on the first layout pass — check with `--snapshot`, which prints the first-pass
height against the settled one.

Section labels take an exception, recorded as **§7.2 汉字排印例外** in the identity standard: §6's
+0.18em tracking is a rule about Latin small caps, which Han does not have, and 8.5 pt is below what
Apple ships as "mini". `Theme.label()` and `Theme.labelTracking()` carry it — 9.5 pt, and tracking
at 0.4× — and nothing else in the interface changes size by language.
