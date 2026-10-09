import Foundation
import os

/// A launchd agent that opens WoW Session Recorder when WoW starts, without anything running in
/// the meantime.
///
/// macOS can't trigger on "app X launched", but launchd can trigger on a file changing, and WoW
/// rewrites a few files in `_retail_/Logs` within a second of starting. The agent's command
/// double-checks that WoW is actually running (and the recorder isn't) before opening it, so
/// stray writes to those files are harmless.
enum WoWLaunchAgent {
    static let label = "io.github.xinding33.wow-session-recorder.open-with-wow"

    /// Written once at WoW startup and not touched again while it runs.
    private static let triggerFiles = ["threadpool.log", "General.log"]

    private static let log = Logger(subsystem: "SessionRecorder", category: "LaunchAgent")

    static var plistURL: URL { plistURL(for: label) }

    private static func plistURL(for label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /// Installs or updates the agent. A no-op when it's already set up for these paths.
    static func install(appURL: URL, retail: URL) throws {
        let plist = makePlist(appURL: appURL, retail: retail)
        if let existing = NSDictionary(contentsOf: plistURL), existing.isEqual(to: plist) {
            return
        }
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        launchctl("bootout", "gui/\(getuid())/\(label)")
        guard launchctl("bootstrap", "gui/\(getuid())", plistURL.path) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "launchd refused the Open with WoW agent."])
        }
        log.info("Installed launch agent watching \(retail.path, privacy: .public)")
    }

    /// Removes the agent, or the one with `label`, such as an earlier version's.
    static func uninstall(label: String = label) {
        let plistURL = plistURL(for: label)
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        launchctl("bootout", "gui/\(getuid())/\(label)")
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func makePlist(appURL: URL, retail: URL) -> NSDictionary {
        let logs = WoWInstall.logsFolder(in: retail)
        // The app path is passed as $0 so it never needs shell quoting.
        let script = #"pgrep -xq "World of Warcraft" && ! pgrep -xq "WoW Session Recorder" && exec open -g -a "$0""#
        return [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", script, appURL.path],
            "WatchPaths": triggerFiles.map { logs.appending(path: $0).path },
            "RunAtLoad": false,
            "ProcessType": "Interactive",
        ]
    }

    @discardableResult
    private static func launchctl(_ arguments: String...) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
