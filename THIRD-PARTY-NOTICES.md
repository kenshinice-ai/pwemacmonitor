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

Copyright (c) 2024 vladkens · MIT Licence · [`licenses/macmon-MIT.txt`](licenses/macmon-MIT.txt)

---

## Apple private interfaces

The app reads hardware telemetry through interfaces Apple does not publish: `libIOReport.dylib` and
the `IOHIDEventSystemClient` family inside IOKit, both resolved at runtime with `dlopen`/`dlsym`.
This is the same approach macmon, Stats and asitop take, and it is the only way to obtain per-core
residency and the SoC energy model on Apple Silicon. These interfaces can change between macOS
releases; the app degrades to "—" rather than failing when they do.

No Apple code is included in this repository.
