import Foundation

/// `pwemon --updatecheck` — what the update check sends, and when it declines to run.
///
/// This app has no XCTest target, so the invariants that matter travel as a self-check the way
/// `--wing-states` and `--bench-icon` do, and `Tools/release.sh` runs it before it builds.
///
/// The invariant worth gating is negative: **the payload is three fields and none of them
/// identify the machine.** That promise is printed in the app and on the download page, so a
/// fourth field added without thinking is a broken promise rather than a bug.
enum UpdateCheckSelfTest {

    @MainActor static func run() -> Int32 {
        var failures: [String] = []

        func expect(_ condition: Bool, _ what: String) {
            print(condition ? "  ✓ \(what)" : "  ✗ \(what)")
            if !condition { failures.append(what) }
        }

        print("update check")

        let payload = UpdateCheck.payload(version: "1.3.0")
        expect(Set(payload.keys) == ["product", "version", "os"], "sends exactly product, version, os")
        expect(payload["product"] == "macmonitor", "names this product")
        for forbidden in ["machine", "order", "tier", "state", "serial", "user"] {
            expect(payload[forbidden] == nil, "never sends \(forbidden)")
        }

        expect(UpdateCheck.isNewer("1.10.0", than: "1.9.0"), "1.10 is newer than 1.9, not older")
        expect(UpdateCheck.isNewer("1.4.0", than: "1.3.0"), "1.4 is newer than 1.3")
        expect(!UpdateCheck.isNewer("1.3.0", than: "1.3.0"), "the same version is not an update")
        expect(!UpdateCheck.isNewer("1.2.9", than: "1.3.0"), "an older answer is not an update")
        expect(!UpdateCheck.isNewer("", than: "1.3.0"), "an empty answer is not an update")

        // Consent, and the daily gate. A throwing transport stands in for the network: what is
        // being measured is whether a request is attempted at all.
        let suite = "PWEMonitorSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var attempts = 0
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let updates = UpdateCheck(defaults: defaults, now: { clock },
                                  fetch: { _ in attempts += 1; throw CancellationError() })

        let group = DispatchGroup()
        group.enter()
        Task { @MainActor in
            await updates.checkIfDue(enabled: false)
            expect(attempts == 0, "off means no request")

            await updates.checkIfDue(enabled: true)
            expect(attempts == 1, "on means a request")

            clock += 60 * 60
            await updates.checkIfDue(enabled: true)
            expect(attempts == 2, "a failed check is retried rather than parked for a day")
            group.leave()
        }
        while group.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        defaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.removeSuite(named: suite)

        print(failures.isEmpty ? "✓ update check" : "✗ update check — \(failures.count) failed")
        return failures.isEmpty ? 0 : 1
    }
}
