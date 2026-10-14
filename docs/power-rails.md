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
14 minutes apart, so one comparison costs half an hour. (Tried again on 2026-10-12 as a witness
for CLPC, and dropped again: see the last section.)

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

So the app subscribes to more CLPC counters than it shows (two in 1.7.0; three since 1.7.1,
below). The CPU counter is the **witness**: it and the
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

## A Mac with no cluster histograms: M3 and M5 Max (1.7.1)

**What 1.7.0 showed.** On two more Macs, both on macOS 27.0.1, the rail under the core row had one
segment — the GPU. Reported 2026-10-12, the day 1.7.0 shipped:

| Mac | CLPC driver | `--probe`, 40 samples in |
|---|---|---|
| iMac, M3 (`Mac15,5`) | `AppleT8122CLPC`, in the table | `cpu — [none]  gpu 2.7 W  ane — [clpc_pending]` |
| Mac Studio, M5 Max (`Mac17,14`) | `AppleT6050CLPC`, in the table | `cpu — [none]  gpu 51 W  ane — [clpc_pending]` |

**Why.** The CPU rail on macOS 27 is the cluster histograms, found by name: `EACC…`, `PACC…`,
`MACC…` in `PMP` / `Energy`. Neither Mac has a channel this app recognises as one. The ANE figure
waits for a witness, and the witness compared CLPC's CPU counter with those same histograms — so
with none, it never spoke. One cause, both rails. The histogram route had only ever been run on the
M4 Max it was written on.

Whether those chips have the histograms under another name is **not verified**: the only listing
taken was a shell pipeline over `ioreg`, which printed nothing on either and may simply not have
matched. `pwemon --channels` (new in 1.7.1) prints the answer from the API the app itself uses.

**What 1.7.1 does.** Where no cluster histogram is found:

- **The CPU figure is CLPC's own CPU counter** (`cpu_source` is `clpc`).
- **The witness is the GPU pair**: CLPC's GPU counter against the Energy Model's `GPU Energy` —
  the one Energy Model counter macOS 27 still updates every second, on every chip. Every 30
  seconds `Sampler.gpuAgrees` compares their means, but only when the GPU averaged 1.5 W or more:
  at rest every counter reads about zero beside it and the comparison says nothing. They agree
  within 0.75 W or a quarter of the reading.
- Until the witness has agreed, nothing changes from 1.7.0: no CPU segment, no ANE.
- One refusal stands for the rest of the run, as with the histogram witness.

Where the histograms exist nothing changes: they stay the CPU figure and the witness.

**An agreement is remembered** (both witnesses, since 1.7.1). It is stored with the macOS build
and the driver (`clpcWitnessed`, for example `26A434|com.apple.driver.AppleT6041CLPC`), and the
next launch on that build shows CLPC's figures from the first sample. A new build of macOS is a
new key, so an update starts from "not witnessed". The witnesses go on checking, and a refusal
removes the entry.

**What the GPU witness rests on.** The two runs of `Tools/compare-rails.sh` above, re-read in
30-second windows, M4 Max, 2026-10-12:

| Energy Model GPU, window mean | CLPC GPU | Judged |
|---|---|---|
| 20.17 W | 20.18 W | agrees |
| 5.07 W | 5.17 W | agrees |
| 5.81 W | 6.25 W | agrees |
| 21.70 W | 22.03 W | agrees |
| 0.21 W, 0.28 W, 0.24 W | 0.21 W, 0.30 W, 0.51 W | not judged: under the floor |

And the path itself, run on the M4 Max with `PWEMON_NO_HISTOGRAMS=1` (which makes the sampler
ignore its histograms) beside an unmodified copy, through `Tools/railprobe`'s loads: no CPU figure
for the first 57 seconds, including 35 with every core busy; then, one window after the GPU load
began, `cpu … [clpc]` and `ane … [clpc]`. From there CLPC's CPU read 0.1–0.4 W where the histogram
read 0.3–0.5 W at rest, 1.7–1.9 W against 1.3–1.6 W under Vision work, and the ANE 3.5 W.

**It is indirect, and says so.** A right GPU entry beside a wrong CPU one would pass. The table's
three entries for a driver come from one extraction, and the indices move together between
releases, which is the case the witness is there for.

**Not verified.**

- CLPC's CPU counter has not been compared with `powermetrics` on an M3 or an M5 Max. On the M4
  Max it read 5.7 % high with every core busy, 0.5–0.8 W high at rest, and 22 % high on one 6.8 W
  load (the table above). Expect the same order on other chips; it is not measured.
- The GPU pair has not been seen on either chip. If the witness never agrees there, 1.7.1 looks
  exactly like 1.7.0 on that Mac.
- A Mac whose GPU never averages 1.5 W over half a minute never gets a verdict. On the M3 iMac the
  GPU read 2.7–4.8 W at 98 % load, so the floor is not far under what that chip does.

**After release, 2026-10-14** (Lee ran 1.7.1's `--probe` and `--channels` on both Macs):

| Mac | What `--channels` showed | 1.7.1 |
|---|---|---|
| M5 Max | Histograms exist, but in group `PMP0`, not `PMP`, and only `MACC0` and `MACC1` — the two clusters of twelve Performance cores. None for the six Super cores (`PACC_0`…`PACC_5` are per-core Energy Model counters). | Witness agreed under a GPU load. `cpu 8.7 W [clpc]`, `ane 0.0 W [clpc]`; the panel shows CPU, GPU and ANE. |
| M3 | `PMP` has no `Energy` subgroup at all: no histograms anywhere. | `cpu — [none]`, `ane [clpc_pending]`: the GPU stayed at 0.2 W, under the witness's floor. |

So on the M5 Max reading `PMP0` would have been worse than CLPC: it would leave out the Super
cluster. CLPC stays the source there. On the M3 CLPC is the only source. The M3 waits for one
half-minute of GPU work; after that the verdict is remembered.

**Tried first, and dropped: the Energy Model's own batch as the witness.** The batch is the CPU's
true energy, late; CLPC's counter summed between two batches should equal it. A 40-minute log on
the M4 Max, 2026-10-12, held **one** batch — 9,358 J, 640 seconds in — and then nothing for the
remaining 29 minutes. A witness needs two to bracket a span. The "6 to 14 minutes" above was what
September's runs saw, not a rule; what makes a batch land is not known. A check that may take an
hour to speak, and could not be verified in an evening, was not shipped.

**Reading the witness (1.7.2).** On the M3, after 1.7.1, the GPU averaged 2.3–3.8 W for 45
seconds and the probe still said `clpc_pending` — not `clpc_refused`. So the witness never judged,
and three causes fit: CLPC gave no GPU reading, a GPU reading out of range, or a CPU reading at or
under 0.1 W. 1.7.1 printed none of them. `--probe` now has a `CLPC` line — the three counters as
read, and where the witness stands with the figures it judged on — and `--json` carries the same
under `power.clpc`:

```
CLPC  cpu 7.6 W  gpu 0.5 W  ane 0.0 W  witness: waiting: the GPU averaged 0.36 W (CLPC 0.54 W), under 1.5 W
```

Also in 1.7.2: a Mac Studio and an iMac each list an `AppleSmartBattery` with nothing in it, which
`--probe` printed as `Batt 0% … cycles 0`. The battery reader now asks `BatteryInstalled`, as the
panel's layout already did.

**What it said on the M3 (2026-10-14, 1.7.2).** With the GPU busy:

```
CLPC  cpu 11 W  gpu 4.2 W  ane 0.0 W  witness: GPU pair: CLPC 4.37 W, Energy Model 2.84 W — refused for this run
```

The witness did judge — the 1.7.1 `pending` was a GPU that had not yet averaged 1.5 W — and
refused: CLPC's GPU counter read 54 % above the Energy Model's, where on the M4 Max and the M5 Max
the two matched under load. That is either a table entry reading some other counter, or two
counters that define "GPU" differently on this chip. The CPU figure CLPC gave (11 W at about 40 %
CPU) is plausible for an M3 but proves nothing by itself. **Not settled.** What would settle it:
`powermetrics` on the M3 beside `pwemon --json`, idle and under GPU load. Until then the M3 shows
what 1.7.0 showed — GPU only — which is the safe way for the witness to fail.

**Settled, the same day: `powermetrics` on the M3.** Lee ran `sudo powermetrics` beside
`pwemon --json` for 60 one-second samples, about 25 at rest and 30 with a video on the GPU:

| M3, mean | `powermetrics` | Energy Model | CLPC |
|---|---|---|---|
| CPU at rest | 5.11 W | — | **5.12 W** |
| CPU under load | 13.26 W | — | **13.26 W** |
| GPU at rest | 0.05 W | 0.05 W | 0.05 W |
| GPU under load | 1.39 W | 1.38 W | 2.49 W |

- **The table fits the M3.** CLPC's CPU counter is `powermetrics`' CPU Power, second by second —
  closer than on the M4 Max, where it read 5.7 % high at full load.
- **CLPC's GPU counter is a GPU counter that counts more.** Zero at rest, rising the second the
  load began, and about a watt above `powermetrics` under it. `powermetrics`' GPU Power is the
  Energy Model's figure. What the extra watt is — GPU SRAM is the obvious candidate — is not known.
- **So 1.7.2's witness was wrong to refuse.** It assumed the two GPU counters agree, which held on
  the M4 Max and the M5 Max and does not on the M3.

**1.7.3.** `Sampler.gpuAgrees` lets CLPC read up to three quarters (at least 2 W) *above* the Energy
Model and still only a quarter (at least 0.75 W) below; the floor drops from 1.5 W to 1.0 W. Over
every 30-sample window of the M3 run the new rule judged 14 and agreed with all 14; it agrees with
every M4 Max and M5 Max pair above; and the M3's own CPU counter read as its GPU's (5–13 W against
1.4 W) and the ANE's zero are still refused. The GPU figure the panel shows is unchanged: the Energy
Model's, which is `powermetrics`'.

Not verified on the M3: the ANE (nothing loaded it during the run).

