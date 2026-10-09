import AppKit
import RecorderCore
import os

/// Takes over from builds made before the Developer ID bundle identifier, so updating keeps
/// your settings. macOS still asks for Screen Recording permission once more, since it
/// remembers that per identifier.
enum LegacyInstall {
    private static let log = Logger(subsystem: "SessionRecorder", category: "LegacyInstall")

    /// Call before `AppSettings` reads its settings.
    @MainActor
    static func migrate() {
        quitRunningBuilds()
        if let identifier = Bundle.main.bundleIdentifier, identifier != LegacyBundle.identifier {
            let copied = LegacyBundle.migrateSettings(to: identifier, in: .standard)
            if copied > 0 { log.info("Copied \(copied) settings from \(LegacyBundle.identifier, privacy: .public)") }
        }
        // The current agent is installed when the launch mode is applied.
        WoWLaunchAgent.uninstall(label: LegacyBundle.launchAgentLabel)
    }

    /// Two recorders would both write `library.json`, so wait (briefly) for an old one to
    /// finish its segment and save before this one loads the library.
    @MainActor
    private static func quitRunningBuilds() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: LegacyBundle.identifier)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        let deadline = Date.now + 10
        while running.contains(where: { kill($0.processIdentifier, 0) == 0 }), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        log.info("Quit \(running.count) running copies of the previous build")
    }
}
