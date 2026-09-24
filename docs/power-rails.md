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
