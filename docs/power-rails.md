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

## macOS 27 reports no CPU, ANE or DRAM energy

Measured 2026-09-24 on an M4 Max, macOS 27.0. Subscribing to the whole `Energy Model` group gives
328 channels — the aggregate `CPU Energy`, every per-cluster `EACC_CPU*` / `PACC*_CPU*`, the
`ECPUDTL*` / `PCPUDTL*` detail channels, `ANE`, `DRAM`, `GPU SRAM` — and every millijoule channel
reads zero over any window, one second or six, idle or with every core pinned. Only `GPU Energy`,
the one channel in nanojoules, still advances. On macOS 26 the same code read the CPU rail at
1.3–3.1 W.

A sweep of all 67 floating-point `P*` keys in the SMC under a CPU-only load found none that tracks
CPU power (the largest rise was 0.09 W). `PSTR`, the whole-system figure the hero prints, is
unaffected.

What the panel does about it: `Snapshot.railsReadable` becomes true the first time the CPU
counter moves — a running CPU never draws exactly nothing over an interval — and until then the
CPU, ANE and DRAM legends read "—", the hero's second figure reads `GPU 0.5 W` instead of
`rails 0.5 W`, and the note under the bar says the rails are not reported. On a macOS that does
report them the flag flips on the first real sample and nothing else changes. `--json` gains
`power.rails_readable`, so a script can tell a zero from an absence.

Not established: whether the counters are withheld from unprivileged processes only (`powermetrics`
runs as root) or gone entirely. That needs a root read to settle, which this app will not do.
