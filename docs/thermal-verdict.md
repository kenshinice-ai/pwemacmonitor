# Magnitudes and verdicts

Added in 1.3.0. The panel used to grade a temperature and a wattage against numbers we had chosen,
and paint the result coral when they were exceeded. Both numbers were wrong, and the way they were
wrong made the panel cry wolf on a healthy machine.

## What was measured

`Tools/thermalprobe` puts every core and the GPU under sustained load, samples through the shipping
`Sampler`, and records what macOS says about it at the same time. Run on an M4 Max (E4 + P12,
64 GB, two fans), 2026-09-09:

| Machine state | CPU avg | CPU peak | GPU | System power | macOS `thermalState` |
|---|---|---|---|---|---|
| Ordinary desktop use, 20–36 % CPU | 67–82 °C | **76–90 °C** | 64 °C | 33–42 W | `nominal` |
| Video render plus a full-load probe | 96–110 °C | **105–117 °C** | 85–91 °C | 96–**143 W** | `nominal` → **`fair`** |

Against the thresholds that were shipping:

- **CPU/GPU hot at 92 °C.** Every one of 147 load samples graded hot. macOS never once said worse
  than `fair` — never `serious`, never `critical`. And ordinary browsing peaked at 89.5 °C, 2.5 °C
  short of a coral panel.
- **Power hot at the chip envelope, coded as 80 W for a Max.** Measured peak was 142.8 W, so the
  table was low by 78 %. Its warm point of 36 W sat below ordinary use, which is why the PWR
  feather was amber almost all the time. On a base-chip Air the warm point was 9.9 W — less than
  the machine draws with the display on and a browser open.

The envelope table read like package-power figures, but `sysPower` is SMC `PSTR`: the whole
machine, display included. It was measuring something other than what it was calibrated against.

## The principle

Two kinds of signal were being drawn the same way.

A **verdict** comes from the OS or a published limit and means something is wrong:
`ProcessInfo.thermalState`, memory pressure, the battery outside Apple's operating range, the SSD
past its vendor rating.

A **magnitude** is a number graded against a threshold we picked: die temperature, watts.

**Verdicts may reach coral. Magnitudes cap at amber.**

This was already the rule for CPU and GPU *load* — `busy()` in the panel caps them, because a GPU
at 100 % is doing what it was asked to do. 1.3.0 finishes the thought.

The point is not that the new thresholds are better guesses. It is that a mis-calibrated magnitude
can now only be **cosmetically** wrong — amber arrives early or late — instead of raising a false
alarm. Coral that fires on nothing teaches the reader to stop looking, which is the one thing this
palette cannot afford.

## What changed

**`thermalState` is displayed, in words, as the first row of the THERMALS card.** Always present,
so its absence never has to be interpreted. Apple's four levels get their consequence rather than
their name:

| Apple | Shown | Colour |
|---|---|---|
| `nominal` | Nominal · 正常 | none |
| `fair` | Slightly elevated · 略高 | none |
| `serious` | Performance reduced · 性能已受限 | amber |
| `critical` | Cooling down · 正在强制降温 | coral |

`fair` is documented as thermals slightly elevated with fans possibly audible. That is a machine
working, not a machine in trouble, so it takes no colour.

**The die temperature channels take their band from the thermal state.** Temperature still fills
the feather — `tempWarm` 95 °C, `tempFill` 110 °C, calibrated on the measurements above — but caps
at amber. `serious` lifts both die channels to amber, `critical` to coral.

**Power can no longer reach coral at all.** Warm at 85 % of a corrected envelope; the battery
conditions folded into the same channel — outside 38/42 °C, below 20/10 % unplugged — keep their
path to coral, because those are real limits.

**Low Power Mode appears in the verdict line** when it is on. It caps performance deliberately, and
a panel that cannot see it leaves the reader hunting for a fault that is a setting.

**The verdict names one condition once.** When the thermal state is what lifted a channel, that
channel is not listed again beside it — otherwise `serious` read as
*Performance reduced · GPU warm · 72 % to its limit*, where the 72 % was the state's own
contribution and the GPU might be cold.

**The temperature bars span 20–120 °C**, not 20–100. At 117 °C every bar pinned to full, exactly
when the row mattered. And the hover no longer claims a throttle point for the die sensors — they
have no published one. It says who decides instead.

## A magnitude on its threshold holds its band (1.6.0)

A reading that sits on a threshold changes band with every sample. Recorded on 2026-10-09 under a
steady load that held the hottest core at 94–96 °C: the verdict line went from "CPU warm" to "All
five channels calm" and back nine times in forty seconds, and the wing in the menu bar blinked with
it. The band is a statement about the machine, and the machine had not changed.

So a magnitude that has turned warm stays warm until it is clearly below the line again:

| Magnitude | Turns warm at | Lets go below |
|---|---|---|
| CPU average, CPU peak, GPU die | 95 °C | 92 °C |
| System power | 85 % of the chip's envelope | 80 % |

While it is held, the feather stands on the warm mark and the line reads "72 % to its limit",
which is what warm has always meant. `Snapshot.held` carries the latch from one sample to the next
and is the only state a band has; `channels()`, the menu-bar figure and the THERMALS row all read
it, so they cannot disagree. Holding never lifts anything to coral.

Only magnitudes are held. A verdict — memory pressure, the battery's range, the SSD's rating, the
thermal state itself — is somebody else's line, and is reported exactly where they drew it.

`Tools/thresholds` replays a reading hovering between 90 and 96 °C: ten band changes without the
hold, two with it.

## Still guesses, and that is now safe

`tempWarm` / `tempFill` and the power envelope table are calibrated on **one machine**. Max is the
measured figure; Base, Pro and Ultra are that correction applied proportionally and are unverified.
On a chip that never reaches 95 °C the die channels simply stay calm, which is true of that machine.

`Tools/thresholds` holds the line that makes this acceptable: it sweeps 0–200 °C and 0–400 W with
macOS reporting nominal and **fails the build if any magnitude reaches hot**, then checks that all
seven verdicts still do. 80,295 assertions.

## Re-measuring on another chip

```bash
swiftc -O -swift-version 5 Sources/Core/*.swift Tools/thermalprobe/main.swift \
  -o /tmp/thermalprobe -framework IOKit -framework Metal
/tmp/thermalprobe 240 60          # 240 s of load, then 60 s watching it fall
```

It will make the fans loud and the machine hot; that is the point. Read the peak line and the
`samples graded HOT by temperature while macOS said nominal` count at the end. Anything above zero
in that count on a machine doing ordinary work means the magnitude thresholds want another look —
never that the machine wants one.

Note that the probe measures whatever else is running too. The first run of this one was taken on a
Mac that turned out to be rendering video throughout, which is why its cooldown phase never cooled.
Check what else is busy before reading the numbers as a baseline.
