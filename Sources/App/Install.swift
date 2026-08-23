import AppKit

/// First-run installation helpers.
///
/// The app is handed around as a disk image, so it frequently ends up being launched straight from
/// the mounted volume or from ~/Downloads. Both cause real problems: a read-only volume cannot be
/// updated, and "launch at login" cannot register an app that lives on one. Offer to move it once.
enum Install {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    static let repositoryURL = URL(string: "https://github.com/kenshinice-ai/pwemacmonitor")!
    static let releasesURL = URL(string: "https://github.com/kenshinice-ai/pwemacmonitor/releases/latest")!

    private static let applications = "/Applications"
    private static let promptedKey = "didOfferToMoveToApplications"

    static var bundleURL: URL { Bundle.main.bundleURL }
    static var isInApplications: Bool {
        bundleURL.deletingLastPathComponent().path == applications
            || bundleURL.path.hasPrefix(NSHomeDirectory() + applications)
    }
    /// True when the app is running from a mounted disk image.
    static var isOnReadOnlyVolume: Bool {
        (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    /// Ask once, on first launch, if the app is not installed anywhere sensible.
    @MainActor static func offerToInstallIfNeeded() {
        guard !isInApplications else { return }
        let defaults = UserDefaults.standard
        guard isOnReadOnlyVolume || !defaults.bool(forKey: promptedKey) else { return }
        defaults.set(true, forKey: promptedKey)

        let alert = NSAlert()
        alert.messageText = "Move PWE MAC MONITOR to your Applications folder?"
        alert.informativeText = isOnReadOnlyVolume
            ? "The app is running from a disk image. Moving it to Applications lets it stay installed, update itself, and start at login."
            : "Keeping it in Applications lets it start at login and keeps it out of your Downloads folder."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try moveToApplications()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Could not move the app"
            failure.informativeText = "\(error.localizedDescription)\n\nDrag PWE MAC MONITOR to your Applications folder in Finder instead."
            failure.runModal()
        }
    }

    private static func moveToApplications() throws {
        let fm = FileManager.default
        let destination = URL(fileURLWithPath: applications).appendingPathComponent(bundleURL.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        // Copy rather than move: the source may be a read-only disk image.
        try fm.copyItem(at: bundleURL, to: destination)
        if !isOnReadOnlyVolume { try? fm.trashItem(at: bundleURL, resultingItemURL: nil) }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
