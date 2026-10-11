import AppKit
import Observation
import RecorderCore
import os

/// Checks GitHub for newer releases and installs them in place of this copy.
@MainActor
@Observable
final class AppUpdater {
    static let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(Version.init)
        ?? Version("0")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Only release builds can install releases: an update must satisfy this copy's code
    /// signature. Reading the signature takes a moment, so it's false until that's done.
    private(set) var canInstall = false
    private let signatureCheck = Task.detached { Updater.isDeveloperIDSigned(Bundle.main.bundleURL) }
    /// What the updater is doing, or nil when it's idle.
    private(set) var status: String?
    /// Whether restarting now would cut into a recording, so the offer to install can say so.
    @ObservationIgnored var isRecording: () -> Bool = { false }

    private let settings: AppSettings
    private let log = Logger(subsystem: "SessionRecorder", category: "Updates")

    init(settings: AppSettings) {
        self.settings = settings
        Task { canInstall = await signatureCheck.value }
    }

    /// When automatic updates are on and a day has passed since the last check, installs any
    /// newer release, as long as `isIdle` says a restart would go unnoticed. Returns whether it
    /// installed one, which then needs `relaunch()` or a quit. Failures are logged and retried
    /// at a later check.
    func installAutomatically(while isIdle: () -> Bool) async -> Bool {
        guard await signatureCheck.value, settings.autoUpdate, status == nil, isIdle(),
              Date().timeIntervalSince(settings.lastUpdateCheck) > Self.checkInterval else { return false }
        status = "Checking for Updates…"
        defer { status = nil }
        do {
            guard let release = try await newerRelease() else { return false }
            return try await install(release, while: isIdle)
        } catch {
            log.error("Automatic update failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Checks now and says what it found, offering to install a newer release.
    func checkForUpdates() {
        guard status == nil else { return }
        status = "Checking for Updates…"
        Task {
            defer { status = nil }
            do {
                let release = try await newerRelease()
                let canInstall = await signatureCheck.value
                let alert = NSAlert()
                guard let release else {
                    alert.messageText = "WoW Session Recorder is up to date"
                    alert.informativeText = "Version \(Self.version) is the latest."
                    await show(alert)
                    return
                }
                alert.messageText = "WoW Session Recorder \(release.version) is available"
                alert.informativeText = "You have version \(Self.version)."
                if !canInstall {
                    alert.informativeText += " This copy was built from source, so it can't update itself."
                } else if isRecording() {
                    alert.informativeText += " Recording stops for a few seconds while the app restarts."
                }
                if canInstall { alert.addButton(withTitle: "Install and Restart") }
                alert.addButton(withTitle: "Release Notes")
                alert.addButton(withTitle: "Later")
                switch (await show(alert), canInstall) {
                case (.alertFirstButtonReturn, true):
                    if try await install(release, while: { true }) { relaunch() }
                case (.alertFirstButtonReturn, false), (.alertSecondButtonReturn, true):
                    NSWorkspace.shared.open(release.page)
                default: break
                }
            } catch {
                log.error("Update failed: \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert(error: error)
                alert.messageText = "Couldn't update WoW Session Recorder"
                alert.informativeText = error.localizedDescription
                await show(alert)
            }
        }
    }

    /// Shows `alert` from the run loop rather than from this task, so the rest of the app (which
    /// may be recording) carries on while it's up.
    @discardableResult
    private func show(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    NSApp.activate()
                    continuation.resume(returning: alert.runModal())
                }
            }
        }
    }

    /// Quits, and opens the copy now at the app's path once this one has gone, so the two never
    /// share the library. (Replacing the process with `execv` is simpler, but macOS 27 won't
    /// give the same process a menu bar item twice.)
    func relaunch() {
        let script = #"while kill -0 "$0" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -g "$@""#
        var arguments = ["-c", script, String(getpid()), Bundle.main.bundlePath]
        let launchArguments = CommandLine.arguments.dropFirst()
        if !launchArguments.isEmpty { arguments += ["--args"] + launchArguments }
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = arguments
        do {
            try reopen.run()
        } catch {
            // Keep running; the new copy takes over at the next launch.
            log.error("Couldn't relaunch: \(error.localizedDescription, privacy: .public)")
            return
        }
        log.info("Relaunching")
        NSApp.terminateFromTask()
    }

    /// The latest release, if it's newer than this copy.
    private func newerRelease() async throws -> Release? {
        let release = try await Updater.latestRelease()
        settings.lastUpdateCheck = Date()
        return release.version > Self.version ? release : nil
    }

    /// Downloads `release` and swaps it in for this copy, unless `isIdle` stopped being true
    /// during the download. Returns whether it was installed.
    private func install(_ release: Release, while isIdle: () -> Bool) async throws -> Bool {
        status = "Installing Version \(release.version)…"
        let zip = try await Updater.download(release)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard isIdle() else {
            // Ask again at the next chance rather than tomorrow.
            settings.lastUpdateCheck = .distantPast
            return false
        }
        log.info("Installing \(release.version.description, privacy: .public)")
        try await Updater.install(zip: zip, version: release.version, replacing: Bundle.main.bundleURL)
        return true
    }
}
