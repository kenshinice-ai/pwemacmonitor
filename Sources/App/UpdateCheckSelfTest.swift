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

        func newer(_ outcome: UpdateCheck.Outcome) -> String? {
            if case .newer(let release) = outcome { return release.version }
            return nil
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
            expect(await updates.check(manual: true) == .unreachable, "no answer is unreachable, not current")

            // What a manual check reports. "Later" quiets the daily reminder; it must not make
            // "Check for Updates…" say the reader has the newest version when they do not.
            var answer = #"{"version":"1.4.0","published":"2026-10-01","download":"https://pwestudio.site/macmonitor"}"#
            let ok = HTTPURLResponse(url: URL(string: "https://pwestudio.site/app/check")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!
            let answering = UpdateCheck(defaults: defaults, now: { clock },
                                        fetch: { _ in (Data(answer.utf8), ok) })
            _ = await answering.check(version: "1.3.0")
            answering.dismiss()
            let daily = await answering.check(version: "1.3.0")
            expect(newer(daily) == "1.4.0" && answering.available == nil,
                   "the daily check respects Later and still knows 1.4.0 exists")
            let asked = await answering.check(version: "1.3.0", manual: true)
            expect(newer(asked) == "1.4.0" && answering.available?.version == "1.4.0",
                   "a manual check shows 1.4.0 even after Later")

            answer = #"{"version":"1.3.0","published":"2026-09-01","download":"https://pwestudio.site/macmonitor"}"#
            expect(await answering.check(version: "1.3.0", manual: true) == .current,
                   "an announced release equal to this build is current")

            // check.js answers a product it does not know with the caller's version and nothing
            // else. That is no information, not "up to date".
            answer = #"{"version":"1.3.0"}"#
            expect(await answering.check(version: "1.3.0", manual: true) == .unknown,
                   "an echo with no release fields is unknown, not current")
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
