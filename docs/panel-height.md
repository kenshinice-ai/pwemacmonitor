# Panel height

The panel is tall. This is where the height goes, what it would cost to get it back, and which
ideas were measured and killed. Everything here was measured off a real render — nothing estimated.

## Where it goes

Measured 2026-09-07 on an M4 Max (E4 + P12, 64 GB, two fans, 2 TB), by scanning
`docs/dashboard-light.png` for the white card runs — cards are `#FFFFFF` on the `#F7F5F2` ground.
Reproduce with the scanner in **Measuring** below.

| Block | 1.2.0 | 1.2.1 |
|---|---|---|
| Header — wing, wordmark, verdict, channel legend | 137 | **118** |
| CPU / GPU / POWER | 98 | 98 |
| Cores + power rails | 152 | 152 |
| THERMALS \| MEMORY | 174 | 174 |
| FANS \| BATTERY | 105 | 105 |
| SSD \| NETWORK | 105 | 105 |
| TOP PROCESSES | 145 | 145 |
| Signature + control bar + inter-module gaps | 154 | 124 |
| **Total** | **1070** | **1021** |

1.3.0 adds one row to THERMALS — macOS's thermal verdict, see `thermal-verdict.md` — and the panel
is 1031 pt (1037 in Chinese). It also ships scheme B below.

Card *content* heights, which is what a re-layout has to work with — a `GridRow` takes its taller
card, so the row figures above hide this:

| Card | Content | Card | Content |
|---|---|---|---|
| THERMALS | 165.5 | BATTERY | 106.0 |
| MEMORY | 173.0 | SSD | 105.0 |
| FANS | 87.5 | NETWORK | 104.0 |

BATTERY, SSD and NETWORK sit within 2 pt of each other. That is the fact every three-across
scheme below is built on.

## The fold

`maxBodyHeight = max(320, NSScreen.main.visibleFrame.height - 190)` clamps the scroll view, so the
panel scrolls once it passes `header + maxBodyHeight + controlBar + 2`.

| Machine | Panel fits up to |
|---|---|
| 16" MacBook Pro | ~1050 pt |
| 14" MacBook Pro | ~967 pt |
| 13" MacBook Air, Dock hidden | ~883 pt |
| 13" MacBook Air, Dock showing | ~813 pt |

1.2.1 at 1021 pt fits a 16" and scrolls 54 pt on a 14".

## What 1.2.1 did

Two changes, deliberately small.

**The verdict moved into the wordmark block** — second line, above the hardware line. It had been a
row of its own under the wing, and the wing is 55 pt against two lines of 27, so a third line lands
in space the header already occupied. It also reads better there: name, then state, then the
hardware you read once. The line has 238 pt beside the wing and the longest reachable verdict
(`Memory warm · 100% to its limit · 另有 4 项`) measures 193.

**Inter-module spacing went 13 → 8** — one step down the Fibonacci scale, not an arbitrary number.
The six cards now read as one block, and the space between modules stopped competing with the
13 pt padding inside them.

Together: **−49 pt**, no reading removed, no card hidden.

## The five schemes

B shipped in 1.3.0; the rest are costed against the measurements above and not implemented.

### A · Density surgery — 377 pt, 985 pt tall

Every reading stays on screen; the chrome and the redundant encodings pay.

- Thermals and fans: the bar moves from below the row to behind it (row 20 → 15 pt) — −45
- Memory: App / Wired / Compressed fold into one legend line under the stacked bar — −34
- Network: four rows become 2 × 2 — −26
- Cores: the E/P frequency legend folds into the card title — −16
- Battery and SSD lose their bars, which repeat the headline — −18
- Processes: row spacing 5 → 3 — −10

**14": still 18 pt over. 13": still ~100 over.** Seven changes to information display for 8 %.
Costs three redundant encodings. Not worth it on its own.

### B · Progressive disclosure — 377 pt, 834 pt tall — **shipped in 1.3.0**

Primary view: header, CPU/GPU/POWER, cores + rails, THERMALS | MEMORY, TOP PROCESSES.
Collapsed: FANS | BATTERY, SSD | NETWORK (and ALL SENSORS, already optional). Toggle sits in the
control bar, costing no height.

Not tabs. Tabs halve the content with neither half complete; here the primary view still answers
*is anything wrong* on its own, and the toggle is sticky in `UserDefaults` exactly like
`showSensors` — set once, never clicked again.

**Fits every machine, 13" included.** Costs four cards behind one click.

Shipped as **Panel Sections** in the settings menu rather than as chevrons on the panel: the
resting interface is unchanged, it costs no height, and it extends the pattern `showSensors` has
used since 1.0. Each row is switchable and remembered. All on by default, so nobody meets a panel
with things missing.

The unit is a **grid row**, not a card, and the menu is grouped that way for a reason — see the
first dead end below.

### C · Three across — 521 pt, 965 pt tall

Widen, and lay the six lower cards three to a row instead of two.

- Row 1 — *pressure*: THERMALS, MEMORY, FANS → 173 (MEMORY governs)
- Row 2 — *flow*: BATTERY, SSD, NETWORK → 106 (all three within 2 pt)

410 → 292, minus one gap. The grouping is also height-optimal: the two tall cards must share a row,
and the semantic alternative (thermals|fans|battery + memory|ssd|network) costs 60 pt more.

Widening pays independently: core bars 21 → 28 pt each, sparklines 110 → 151 pt, process names stop
truncating, hero numbers stop hitting `minimumScaleFactor`.

Width is set by the widest thing in a card, measured at 10 pt Inter:

| | pt |
|---|---|
| Title `SSD · MACINTOSH HD` | **118.3** ← the binding constraint |
| `Health 100% · 12 cycles` | 114.7 (Chinese 113.3) |
| `Address 192.168.1.42` | 101.5 |
| `Compressed 14.7 GB` | 100.8 |

`(W − 68) / 3 − 26 ≥ 118.3` → **W ≥ 501**. 521 = 377 + 144, both Fibonacci, leaving 7 pt.

**965 against a 967 fold is not a margin.** One more fan or a longer volume name crosses it.

### C+ · Three across with A's cheapest moves — 521 pt, 929 pt tall

C, plus the thermals/fans row background, the memory legend and the battery bar. **14" fits with
38 pt to spare. 13" still scrolls 44.**

### D · Three across at 466 pt — 466 pt, 881 pt tall

Drop the volume name — `SSD · MACINTOSH HD` 118.3 → `SSD` 21.7 — and the binding constraint
disappears. A 466 pt panel gives 106.7 pt of usable card width, and everything fits:

| | pt | |
|---|---|---|
| `Compressed 14.7 GB` | 104.5 | ✓ |
| `Address 192.168.1.42` | 105.1 | ✓ (1.6 spare; the value scales to 0.75 before truncating) |
| `NETWORK · EN0` | 87.5 | ✓ |
| `+0.0 W · 100% · 12 cycles` | 109.9 | ✗ by 3 — drop the spaces around the separators |
| `↓ 346 KB/s ↑ 12.9 MB/s` | 109.6 | ✗ by 3 — same fix |

Content changes: thermals and fans get the row background; battery merges Flow and Health into one
line under the bar; SSD merges Read and Write; network merges Down and Up; memory drops Cached.
Grid 410 → 251. With the 1.2.1 header, **881 pt**.

**The only readings actually removed are the volume name and Cached.** Everything else is
re-arrangement. **14" fits with 86 pt to spare** — the only scheme with a real margin. 13" is
borderline: fits with the Dock hidden, scrolls ~68 pt with it showing.

One implementation note: `SectionLabel` is `fixedSize(horizontal: true)`, so it overflows rather
than truncating. Fine at 377; at 466 a `NETWORK · BRIDGE0` would run past the card. It needs
`.truncationMode(.tail)` before any narrow-card scheme ships.

### Side by side

| | Width | Height | 14" | 13" Air | Actually removed |
|---|---|---|---|---|---|
| 1.2.0 | 377 | 1070 | scrolls 103 | scrolls 185 | — |
| **1.2.1** | **377** | **1021** | scrolls 54 | scrolls 138 | nothing |
| **1.3.0** | **377** | **1031** | scrolls 64 | scrolls 148 | nothing — and any row can be switched off |
| A | 377 | 985 | scrolls 18 | scrolls 100 | 3 redundant encodings |
| B | 377 | 834 | ✓ | ✓ | 4 cards behind a click |
| C+ | 521 | 929 | ✓ 38 spare | scrolls 44 | 3 redundant encodings |
| D | 466 | 881 | ✓ 86 spare | borderline | volume name, Cached |

D and B combine: D's layout with B's toggle on the *flow* row reaches ~776 pt and clears a 13" with
the Dock showing.

## Dead ends

Measured, and wrong. Recorded so they are not proposed again.

**Re-pairing the grid rows saves nothing.** A `GridRow` takes its taller card. The four cards run
74 / 88 / 89 / 106 pt, and no pairing beats 106 + 89 — the original order was already at that bound.
1.2.0 shipped a re-pairing believing it saved 65 pt; it saved 1 pt and was kept only because the
grouping reads better.

**The memory legend does not fit a narrow card.** Folding App / Wired / Compressed into one line,
the way the power rails do, needs about 200 pt. A three-across card at 466 has 106.7. It works only
in a two-across card, which is why it appears in A and not in D.

**Two-column memory does not fit either.** Each half would get 50.4 pt; `Compressed 14.7` alone is
82.4. Memory keeps labelled rows — that pairing is exactly what makes the card readable — and only
`App 23.8 · Wired 7.0` (95 pt) fits on a shared line.

**Merging FANS into THERMALS makes the panel taller.** FANS rides in a row whose height is set by
its neighbour, so it is currently free; moving its two rows into THERMALS adds 54 pt to a card that
already governs its row, for a net +34.

## Measuring

Card and content heights, from a render rather than from the source:

```bash
"build/PWE MAC MONITOR.app/Contents/MacOS/pwemon" --snapshot docs --demo
```

`--snapshot` prints the first-pass height against the settled one — they must be equal, or the
popover resizes after it opens. Add `-language zh-Hans` for the Chinese layout, which runs a few
points taller.

To measure a card, scan a column inside its own left padding, where no text falls; a white run is
one card. Stay 5 pt inside every edge — the rounded-rect stroke runs the card's full height and
will otherwise read as content. Text widths come from `CTLineGetTypographicBounds` with the
bundled Inter registered through `CTFontManagerRegisterFontsForURL`; that is how every figure in
this file was produced.
