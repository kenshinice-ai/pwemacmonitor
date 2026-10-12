# Third-party notices

PWE Monitor bundles or derives from the following third-party work. Full licence texts are in
[`licenses/`](licenses/).

---

## macmon — MIT

**This project owes its existence to [macmon](https://github.com/vladkens/macmon) by vladkens.**

The low-level Apple Silicon telemetry in `Sources/Core/` — the IOReport subscription and energy /
residency decoding, the `AppleSMC` key protocol, the IOHID temperature-sensor client, and the pmgr
DVFS frequency tables — is a Swift port of macmon's Rust implementation. The channel names, the
`KeyData` struct layout, the residency-to-frequency maths and the per-chip quirks were all worked
out there first, and this port would not have been feasible without that source to read.

Since 1.7.0 `Sources/Core/CLPC.swift` also carries macmon's table of AppleCLPC report IDs for
macOS 27 (`src/clpc.rs` at commit `afdd572`), which its author extracted from Apple's kernelcaches.
The table is data, reproduced with that attribution; the code around it, and the check that decides
whether to believe it, are this project's.

Copyright (c) 2024 vladkens · MIT Licence · [`licenses/macmon-MIT.txt`](licenses/macmon-MIT.txt)

---

## Apple private interfaces

The app reads hardware telemetry through interfaces Apple does not publish: `libIOReport.dylib` and
the `IOHIDEventSystemClient` family inside IOKit, both resolved at runtime with `dlopen`/`dlsym`.
This is the same approach macmon, Stats and asitop take, and it is the only way to obtain per-core
residency and the SoC energy model on Apple Silicon. These interfaces can change between macOS
releases. When a reading stops arriving the panel leaves it out or draws a dash, and `--probe`
prints a dash; `--json` keeps its older numeric keys and says in `power.readable` and
`memory.pressure_level` which of them were actually read.

No Apple code is included in this repository.
