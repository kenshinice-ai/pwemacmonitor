# The power rails

The stacked bar in the silicon card: CPU, GPU, Neural Engine and DRAM power from IOReport's energy
model. 1.5.0 changed how it is scaled and coloured, and found that on macOS 27 most of it is no
longer reported at all.

## Scale: the chip, not the four rails' own sum

Until 1.5.0 the bar was normalised to the four rails' total. With 0.2 W on the GPU and nothing
elsewhere, the GPU was 100 % of the total and the bar was drawn full — an idle Mac looked maxed.

It is scaled to the chip's envelope now (`Snapshot.powerEnvelope`, 140 W on a Max), so its length
is how much of the machine is in use: a hairline at idle, a third of the way under a full GPU load
(46 W on an M4 Max). The segments' proportions to one another are unchanged.

## Colour: status from the rail's own reading, identity from ink

The leading rail used to be amber by rank — whatever it drew. `Theme.seriesPrimary` was the same
value as `Theme.health(.warm)`, so an idle Mac carried amber on every P-core, on the memory App
segment and on whichever rail happened to lead. Amber had already been defined, in 1.3.0, as *this
is working hard*; those four places contradicted it permanently.

Now every composition segment is drawn in a neutral four-step ink ramp — `[0.70, 0.52, 0.36,
0.24]`, measured against the bar's own track at 1.53:1 light / 2.01:1 dark for the lightest,
where the old three-step ramp bottomed out at 1.37:1 — and takes the status colour only from its
own reading:

| Element | Colour |
|---|---|
| CPU rail | `busy(cpuLoadHealth)` — the same function that colours the CPU figure in the hero |
| GPU rail | `busy(gpuLoadHealth)` — likewise |
| ANE, DRAM rails | ink; neither has a load reading |
| Each core bar | that core's own load, on `cpuLoadHealth`'s thresholds |
| Memory segments | ink; the memory headline already carries the pressure colour |

Because the rail and the hero read the same function, they cannot disagree. `busy` caps load at
warm, so none of these is ever coral: a busy core is working, not failing.

The one amber that is not status is the selected refresh-interval chip. It is a control state,
not a reading, and stays.

## macOS 27: the counters arrive in batches, and the CPU comes back from histograms

**What changed.** On macOS 27 the Energy Model's millijoule counters — `CPU Energy`, every
per-cluster `EACC_CPU*` / `PACC*_CPU*`, `ANE`, `DRAM`, `GPU SRAM` — no longer advance per sample.
They land in batches: zero, zero, zero, then minutes of energy at once. On this M4 Max the
batches came 6 to 14 minutes apart (one carried 9,100 J). Only `GPU Energy`, the one nanojoule
channel, still advances every second. The same failure is open against the other tools that read
IOReport: macmon ([#76](https://github.com/vladkens/macmon/issues/76)) and Stats
([#3608](https://github.com/exelban/stats/issues/3608)). Across all 12,192 IOReport channels,
subscribed either way the open tools do, `GPU Energy` is the only energy-unit counter that moves.

1.5.0 got this half right: it saw zeros and printed "—". But it treated "has ever moved" as live,
so the first batch — several minutes of energy over a two-second interval — would have drawn a
spike of a hundred watts or more, then gone back to zero.

**What still updates every second.** The `PMP` group's `Energy` subgroup holds a power histogram
per cluster: `EACC0` (E-cluster, 32 bands of 0.25 W), `PACC0` / `PACC1` (P-clusters, 32 bands of
2 W), `AGX` (GPU, 2 W), each with a `… SRAM` twin. A cluster that is powered down logs no
residency, so the bands' total understates the interval; the shared tick clock (about 4.4 kHz
here) is learned as the fastest total seen, and the missing residency counts as 0 W.

`Sampler.clusterWatts` takes each band at its midpoint (the states are named by upper edge) and
sums the primary histograms, not the SRAM twins. That rule was settled on the GPU, the one rail
where both a histogram and a working counter exist:

| GPU | Counter | Histogram, midpoint, no SRAM |
|---|---|---|
| Idle | 0.39 W | 1.35 W |
| Full compute load | 46.52 W | **46.30 W** (−0.5 %) |

Under load it is exact to half a percent. At idle it reads high by up to half a band — the
lowest band is 0–2 W and counts as 1 W — and no arithmetic can recover resolution the histogram
does not have. The E-cluster's bands are 0.25 W, so it is eight times finer.

**What the panel does.** Per sample: the Energy Model's CPU counter counts as live only if it
moved this sample *and* the last — a running CPU never draws nothing over an interval, and a
batch after zeros is minutes of energy, so it is discarded. Live, the counter is used as before,
ANE and DRAM with it. Not live, CPU power comes from the cluster histograms, and ANE and DRAM —
which have no histogram — are left off the bar and the legend rather than shown as zero.
`--json` reports `power.cpu_source` (`energy_model`, `pmp_histogram` or `none`) and
`power.rails_readable` (all four rails measured this sample).

The footnote that used to sit under the bar is gone; what the rails cover is in the POWER
column's hover.

**Checking the CPU figure.** The GPU calibration settles the method; the CPU's own reference is
`powermetrics`, which runs only as root. `Tools/compare-powermetrics.sh` asks for the password once
and prints the two side by side, second by second — add `--load` to pin every core while it runs.
Waiting on the Energy Model's own batches as a reference was tried and dropped: they arrive 6 to
14 minutes apart, so one comparison costs half an hour.

First run, 2026-09-24, M4 Max, `--load`, twelve one-second samples:

| Source this app used | Samples | Against powermetrics |
|---|---|---|
| Cluster histograms | 2 | 12.70 vs 12.91 W (−1.6 %), 13.62 vs 12.21 W (+11.5 %) |
| Energy Model counter | 10 | about 8 % low throughout, one sample at 21.69 W against 12.07 |
| **All twelve, mean** | | **12.38 vs 12.26 W (+1.0 %)** |

Two things this taught. **While powermetrics runs, the Energy Model counters go back to updating
every second** — the app switched to them by itself for the middle ten samples. So macOS 27 has not
removed them; it batches them when no privileged client is asking. And one of those per-second
samples still carried a partial batch (21.69 W), which the two-in-a-row liveness test does not
catch — fixed in 1.5.2: `Sampler.cpuPower` sets the counter aside for any sample in which it reads
more than 1.4 × the histogram plus 2 W, and ANE and DRAM hold their last good figures for that
sample. `Tools/thresholds` pins the 21.69-against-12.07 case and the honest cases around it. Two histogram samples is too few to call the histogram's accuracy on the CPU; it wants a
longer run with the counter kept out of the way.

## Every rail against powermetrics, and the Neural Engine back (1.7.0)

Two things prompted this. macmon 0.9.0 restored its power figures on macOS 27 through the CLPC
driver's own energy counters, which raised the question of whether this app should do the same.
And the note just above — two histogram samples is too few — had stood for three weeks.

**The run.** `Tools/compare-rails.sh`, 2026-10-12, M4 Max, macOS 27.0.1 (26A434), twice: 148 and
107 one-second samples. `powermetrics` runs as root beside `Tools/railprobe`, which does not, through
quiet, every core busy, the GPU busy, and Vision work for the Neural Engine. Thermal pressure
stayed nominal throughout.

| Rail | Source | Quiet | Under load | Decision |
|---|---|---|---|---|
| CPU | Cluster histograms — what the app uses | 0.56–0.87 W high | 22.72 W against 21.84 W: **+4.0 %** | **kept** |
| CPU | CLPC counter | 0.49–0.82 W high | 23.08 W: +5.7 %; +22 % on one 6.8 W load | not used for display |
| CPU | Energy Model counter | — | within 0.1 % | per-second only while `powermetrics` runs |
| GPU | Energy Model counter — what the app uses | matches | 41.47 W against 41.51 W: −0.1 % | **kept** |
| GPU | CLPC counter | often 0.5 W high | −0.1 % | not used |
| ANE | CLPC counter | 0 against 0 | 3.581 W against 3.579 W: **+0.1 %**, both runs | **adopted** |
| DRAM | Energy Model counter | 0.4–2.0 W | — | still batched without root; still left out |

What that settled:

- **The histogram is the best CPU figure an unprivileged process can have.** It is 4 % high with
  every core busy. The counter that looked like an upgrade is further off.
- **Its idle offset may not be an error.** This document has explained the histogram's extra
  0.7 W at idle as the midpoint of the lowest band. But CLPC's counter — an energy counter, with no
  bands — reads the same 0.7 W above `powermetrics`, and the two agree with each other: 1.62 W and
  1.62 W. Two independent routes to one number suggest `powermetrics`' "CPU Power" leaves something
  out that both of them include. **Not established**, and nothing is changed on the strength of it.
- **CLPC's GPU counter is not the Energy Model's.** In the second run it sat about half a watt
  higher in every phase but the GPU's own. Unexplained; the Energy Model matches `powermetrics`.
- **The Neural Engine's rail is back on macOS 27**, from the one CLPC counter that checked out.

**How ANE is read, and why it is not simply trusted.** `Sources/Core/CLPC.swift` holds macmon's
table: seventeen CLPC drivers, each with a key per counter, and the table indices for macOS 27. An
IOReport ID is `(index << 32) | key`, and the index belongs to the OS release — the ANE's moved
from 23 to 24 between macOS 26 and 27. The table was extracted from Apple's kernelcaches for 27.0
and 27.0.1; nothing in it says when it stops being right, and a wrong ID reads some other counter
without complaint.

So the app subscribes to two CLPC counters, not one. The CPU counter is the **witness**: it and the
histograms measure the same clusters by different routes, and in both runs their 30-second means
were within 0.4 W of each other. Every 30 seconds `Sampler.clpcAgrees` compares them. While they
agree to within 1.5 W or a quarter of the reading, the ANE figure is shown. The first time they do
not, CLPC is set aside for the rest of the run and the ANE rail disappears — which is what 1.6.0
showed. `--probe` prints the source beside each figure.

On macOS 26 and earlier none of this runs: the Energy Model is live and supplies ANE and DRAM as
it always did.

**After a macOS update.**

1. Run `"build/PWE Monitor.app/Contents/MacOS/pwemon" --json --samples 40 --interval 1`.
   Expected: `power.ane_source` is `clpc` from about the thirtieth line on. If it stays `none`, the
   witness has refused the table or the driver is not in it; the app is already showing the 1.6.0
   rails and nothing is wrong on screen.
2. If it stays `none`, check whether macmon's `src/clpc.rs` has a table for the new version.
   Copy the indices and keys into `CLPC.swift`, and extend the `osMajor` test there.
3. Run `Tools/compare-rails.sh` (it asks for your password; about two and a half minutes).
   Expected: its report puts CLPC's ANE within a few percent of `powermetrics` in the `ane` phase.
   Do not ship a new table without this step.

> ⚠️ Do not widen `CLPC.reportIDs` to an OS version the table was not extracted from.
> The IDs would be accepted and would read whatever counter now sits at those indices.
> The witness catches a wrong CPU counter; it cannot see a wrong ANE counter beside a right CPU one.

Cost: the two counters add about half a millisecond a sample (9.0 → 9.6 ms for IOReport with all
three, measured on the app's queue).
