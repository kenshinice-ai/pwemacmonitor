# What a sample costs, and three readings that were wrong

Written for 1.6.0, from measurements taken on 2026-10-09 and 2026-10-10 on an M4 Max MacBook Pro
running macOS 27.0.1. Every figure here came from a run, and the tools that produced them are in
the repository.

## The app that ended itself after six days

Every release from 1.0.0 to 1.5.2 leaked one Mach port per sample on a Mac with a battery.

`ioFirstProperties()` asked the IORegistry for an iterator, took the first match and returned.
`IOServiceIterator` released its iterator only when `next()` ran off the end, so a caller that
stopped early kept the port. `BatteryStats.read()` is that caller, once per sample. A desktop has
no `AppleSmartBattery`, runs the iterator to its end and does not leak.

The kernel ends a process whose port table reaches about 267,700 entries. It does this silently:
no crash report, no log line naming a reason, and launch-at-login does not start it again.

| Refresh interval | Time awake until the app disappears |
|---|---|
| 1 s | about 3 days |
| 2 s (the default) | about 6 days |
| 5 s | about 15 days |

Observed, not predicted. A test process that leaked the same way was ended between 267,511 and
267,761 ports, and the installed 1.5.2 — started six days and nine hours earlier — was ended at
23:47:36 on 2026-10-09 with 267,724 ports on the last reading before it went.

The leak did not make sampling slower: `sample()` cost the same at 28 ports and at 260,000. It
showed only as memory, 53 MB against 18 MB for a fresh process, and then as the end.

**The fix** is that `IOServiceIterator` is a class and releases in `deinit`.
**The check** is `pwemon --portcheck`: two hundred samples, the port count before and after.
`Tools/release.sh` runs it before anything is built to ship. To look at a running copy:

```bash
top -l 1 -pid $(pgrep -x pwemon) -stats pid,command,ports
```

A few hundred is ordinary. A number that grows by thirty a minute is this bug.

## Three readings that were wrong

**Die sensors dropped for the life of the process.** At launch, an SMC temperature key was kept
only if it read above zero at that instant. A cluster that is powered down reads zero. Of the same
146 CPU keys, six launches in a row kept 146, 146, 146, 116, 146 and 146, and an earlier one kept
74 — so whichever cores were asleep when the app started could later get as hot as they liked
unseen. Keys are now kept by type, and the live subset is re-classified every 10 s instead of 60.

**Network throughput.** Three faults, all found by comparing with `netstat -ib`:

- An unprivileged process is given interface byte counters truncated to 32 bits, whichever API it
  asks. The Wi-Fi link had carried 118.6 GB and read 2.6 GB. Totals are therefore meaningless;
  differences are taken per link in 32-bit arithmetic, where a wrap comes out right. Before, the
  links were summed first, and the rate printed zero whenever any one of them passed a multiple of
  4.29 GB.
- A VPN's `utun`, a relay's `anri` and the Thunderbolt bridge report the same bytes as the adapter
  they ride on, and were added on top of it. Only the adapters are counted now: `en`, `awdl`,
  `llw` and `pdp_ip`.
- The link named in the card's title was "the one with the largest total" — of wrapped totals. It
  is now the one carrying the most at the moment, smoothed, and it has to be out-carried two to
  one before it gives way.

**The battery's temperature verdict.** macOS 27 no longer publishes `Temperature` on the gas
gauge's registry entry. The figure the battery verdict grades read zero, so "outside 38–42 °C"
could never fire. It now falls back to the IOHID sensor on the same cell, which the THERMALS row
was already showing.

## What a sample costs

Measured with `Tools/bench`: on a `.utility` queue, one sample every 2 s, CPU time on the sampling
thread. Per sample, panel closed:

| Path | CPU | Share of a core at 2 s | Wall clock |
|---|---|---|---|
| Panel closed | **11.2 ms** | 0.56 % | 54 ms |
| Panel open | 14.5 ms | 0.72 % | 54 ms |
| Panel open, "all sensors" on | 16.9 ms | 0.84 % | 116 ms |

Taken 2026-10-10. The same measurement of 1.5.2 the day before read 19.7 ms with the panel closed.
Most of the wall clock is waiting on the SMC and costs nothing.

The whole app, panel closed, default 2 s interval, full menu-bar text, 60 s of `proc_pid_rusage`:

| Version | Share of a core | Footprint | Mach ports |
|---|---|---|---|
| 1.5.2, fresh | 2.1–2.4 % | 18 MB | 207, and one more every sample |
| 1.5.2, six days old | 2.3 % | 53 MB | 267,000 |
| **1.6.0** | **1.5–1.8 %** | 18 MB | 190, flat |

Four windows for 1.6.0 on 2026-10-10: 1.77, 1.60, 1.70 and 1.46 %. The footprint is with the panel
never opened; opening it once brings in the interface and settles near 50 MB.

Where it goes, and what was done about each (per sample, 1.5.2, same queue and spacing):

| Source | CPU | In 1.6.0 |
|---|---|---|
| IOReport | 8.5 ms | Unchanged. It is one kernel call, `IOReportCreateSamples`; dropping a channel group saves little and loses a reading. |
| Process table, 1,500 processes | 5.3 ms | Every 10 s while the panel is closed, every sample while it is open. Names are looked up for the eight that make the list, not for all of them. |
| SMC die keys | 2.9 ms | Unchanged in cost. Reading only the hottest few would save 2 ms and miss a cluster that wakes. |
| Disk | 2.0 ms | One registry key instead of the driver's whole table (0.49 → 0.13 ms); volume capacity every 60 s instead of 20 — it is a 20 ms round trip to a daemon. |
| Battery | 0.5 ms | Unchanged. |

About 11 ms more is the main thread redrawing the status item: a Core Animation flush, and AppKit
snapshotting the item again for the menu bar's other copies. That is the price of live figures in
the menu bar. Skipping a redraw when nothing changed was measured and is not worth having: with
the text styles, 1 refresh in 27 was identical to the one before.

## Two ways the old figures were wrong

The README used to say 19 ms a sample, 1.3 ms for the process table and 1.1 % of a core.

- **A tight loop runs on a performance core at full clock.** The app's queue is given an
  efficiency core at whatever it is idling at. The same `sample()` took 8.9 ms of CPU in a loop
  and 19.7 ms in the app.
- **The wall clock counts waiting.** A sample spends about 28 ms blocked on the SMC, which costs
  nothing.

`Tools/bench` now measures on the app's queue, at the app's spacing, in CPU time.
