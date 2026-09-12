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
    private static let oldNamePromptedKey = "didOfferToRemovePredecessor"

    /// What the bundle was called before 1.4.0. Kept as a literal because that is exactly what it
    /// is: a filename that exists on machines already, not a name the product still uses.
    private static let predecessorName = "PWE MAC MONITOR.app"

    static var bundleURL: URL { Bundle.main.bundleURL }
    static var isInApplications: Bool {
        bundleURL.deletingLastPathComponent().path == applications
            || bundleURL.path.hasPrefix(NSHomeDirectory() + applications)
    }
    /// True when the app is running from a mounted disk image.
    static var isOnReadOnlyVolume: Bool {
        (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    /// Offer, once, to throw away the copy that used to be called PWE MAC MONITOR.
    ///
    /// 1.4.0 renamed the bundle. Homebrew handles that on its own — it uninstalls using the cask
    /// definition saved when the old version was installed, which still names the old app — but
    /// somebody who installed by dragging from the disk image now has two bundles carrying the
    /// same identifier. macOS then picks between them for "launch at login" and for anything that
    /// opens the app by identifier, and the one it picks is not predictable. That is the actual
    /// harm, and it is worth one question to avoid.
    @MainActor static func offerToRemovePredecessorIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: oldNamePromptedKey) else { return }
        let old = URL(fileURLWithPath: applications).appendingPathComponent(predecessorName)
        guard FileManager.default.fileExists(atPath: old.path),
              old.standardizedFileURL != bundleURL.standardizedFileURL else { return }
        defaults.set(true, forKey: oldNamePromptedKey)

        let alert = NSAlert()
        alert.messageText = L("rename.title", "An older copy called PWE MAC MONITOR is still installed.")
        alert.informativeText = L("rename.body", "The app is now called PWE Monitor. Two copies share one identity, so macOS cannot tell which one to start at login. Moving the old one to the Trash fixes that; nothing you have set is lost.")
        alert.addButton(withTitle: L("rename.trash", "Move Old Copy to Trash"))
        alert.addButton(withTitle: L("rename.keep", "Keep Both"))
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // The Trash, never a delete: the reader can change their mind, and this is their copy of
        // an application, not our temporary file.
        do {
            try FileManager.default.trashItem(at: old, resultingItemURL: nil)
        } catch {
            let failure = NSAlert()
            failure.messageText = L("rename.failed", "Could not move the old copy")
            failure.informativeText = error.localizedDescription + "\n\n"
                + L("rename.dragInstead", "Drag PWE MAC MONITOR from your Applications folder to the Trash in Finder instead.")
            failure.runModal()
        }
    }

    /// Ask once, on first launch, if the app is not installed anywhere sensible.
    @MainActor static func offerToInstallIfNeeded() {
        guard !isInApplications else { return }
        let defaults = UserDefaults.standard
        guard isOnReadOnlyVolume || !defaults.bool(forKey: promptedKey) else { return }
        defaults.set(true, forKey: promptedKey)

        let alert = NSAlert()
        alert.messageText = L("install.title", "Move PWE Monitor to your Applications folder?")
        alert.informativeText = isOnReadOnlyVolume
            ? L("install.fromDisk", "The app is running from a disk image. Moving it to Applications lets it stay installed, update itself, and start at login.")
            : L("install.fromElsewhere", "Keeping it in Applications lets it start at login and keeps it out of your Downloads folder.")
        alert.addButton(withTitle: L("install.move", "Move to Applications"))
        alert.addButton(withTitle: L("install.notNow", "Not Now"))
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try moveToApplications()
        } catch {
            let failure = NSAlert()
            failure.messageText = L("install.failed", "Could not move the app")
            failure.informativeText = error.localizedDescription + "\n\n"
                + L("install.dragInstead", "Drag PWE Monitor to your Applications folder in Finder instead.")
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
