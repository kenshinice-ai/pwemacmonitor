import Foundation

/// The update check.
///
/// This app had a menu item called "Check for Updates…" that opened the GitHub releases page and
/// left you to compare version numbers yourself. That is a link, not a check — and the people it
/// has to work for are not all people who read release pages.
///
/// **What it sends is the whole of it: the product, this build's version, and the macOS
/// version.** No machine fingerprint, no account, no readings. PWE Loan Bar's equivalent does
/// send a fingerprint, because it counts seats against a licence; this app has no licence and so
/// nothing to count.
///
/// The daily background check is off until it is turned on. Pressing "Check for Updates…" is
/// itself consent for that one check — someone who asks a question has asked it.
///
/// **This file is duplicated in three apps, deliberately, and the duplication is checked.**
/// PWE AI Bar, PWE Monitor and PWE Lumen Bar each carry a copy differing only in `product`, in
/// `downloadPage`, and in which function answers "is the interface in Chinese".
///
/// A shared package was designed and then measured against what it would buy. Three repositories
/// and three build systems -- SwiftPM, a raw `swiftc` line, and an Xcode project -- mean a package
/// costs a fourth repository, a build-system migration for one app, and "edit, tag, bump three
/// dependents" on every change: the same work moved somewhere else, plus a mechanism to learn.
/// What the duplication actually costs is one thing, and only one: nobody being told when a fix
/// reaches one copy and not the others.
///
/// `07 TOOLS/check-shared-sources.py` is that one thing. It compares the five functions carrying
/// the behaviour, ignores the configuration that is supposed to differ, and all three release
/// scripts run it. **Change all three -- and the release will tell you if you did not.**
@MainActor
final class UpdateCheck: ObservableObject {

    /// Decoded leniently, because a field added next year must not break a copy shipped this
    /// year — and that old copy is precisely the one that needs to hear there is a new one.
    struct Release: Decodable, Equatable {
        let version: String
        var published: String?
        var notes_en: String?
        var notes_cn: String?
        var download: String?

        var notes: String? {
            let (own, other) = Loc.isCJK ? (notes_cn, notes_en) : (notes_en, notes_cn)
            return own?.isEmpty == false ? own : other
        }
    }

    @Published private(set) var available: Release?

    /// Where someone goes to get it. The product page, not the file: it states the checksum and
    /// what the download contains, and a download that begins with no explanation is the one a
    /// careful person cancels.
    nonisolated static let downloadPage = URL(string: "https://pwestudio.site/macmonitor")!

    private let endpoint = URL(string: "https://pwestudio.site/app/check")!
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    private let lastCheckKey = "updateLastCheck"
    private let dismissedKey = "updateDismissedVersion"

    nonisolated static let interval: TimeInterval = 24 * 60 * 60
    nonisolated static let product = "macmonitor"

    /// The short version alone. `Install.version` appends the build number for the menu, and
    /// "1.3.0 (14)" compares as nonsense.
    nonisolated static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    nonisolated static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
             try await URLSession.shared.data(for: $0)
         }) {
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
    }

    /// Runs at most once a day, does nothing without consent, and fails silently.
    func checkIfDue(enabled: Bool?, version: String = UpdateCheck.currentVersion) async {
        guard enabled == true else { return }
        if let last = defaults.object(forKey: lastCheckKey) as? Date,
           now().timeIntervalSince(last) < Self.interval { return }
        await check(version: version)
    }

    /// The check itself. Returns whether the server answered at all, so a menu item that was
    /// pressed can say "could not reach the site" instead of nothing.
    @discardableResult
    func check(version: String = UpdateCheck.currentVersion) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.payload(version: version))

        guard let (data, response) = try? await fetch(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return false }

        // Only an answered round trip counts as "checked today"; offline today must not cost
        // tomorrow's check.
        defaults.set(now(), forKey: lastCheckKey)

        guard Self.isNewer(release.version, than: version),
              defaults.string(forKey: dismissedKey) != release.version else {
            available = nil
            return true
        }
        available = release
        return true
    }

    /// Everything that leaves the machine, in one place, so reading this function is the whole
    /// audit. A test fails if a key is ever added to it.
    nonisolated static func payload(version: String) -> [String: String] {
        ["product": product, "version": version, "os": osVersion]
    }

    /// Hides it for this version only. A later release says so again.
    func dismiss() {
        if let version = available?.version { defaults.set(version, forKey: dismissedKey) }
        available = nil
    }

    /// Numeric, component by component, so 1.10 is correctly newer than 1.9 — which a string
    /// comparison gets backwards, and which this project will reach.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
