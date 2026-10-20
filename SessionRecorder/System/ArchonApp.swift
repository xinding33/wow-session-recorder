import AppKit

/// The Archon app, Warcraft Logs' uploader since the old Warcraft Logs Uploader retired.
///
/// It's handed a file to upload on its command line (`--operation-name uploadALog --file-path …`),
/// which it reads only when it starts, so a running copy has to be restarted to take one. It
/// starts the upload once it's signed in and its Logs folder (on its Live Log page) is set,
/// using the guild, region and visibility last chosen in it.
enum ArchonApp {
    /// The full app first, then Archon App Lite, which only uploads logs.
    static let bundleIDs = ["archon", "archon-lite"]

    static let downloadURL = URL(string: "https://github.com/RPGLogs/Uploaders-archon-lite/releases/latest")!

    /// A running copy if there is one, otherwise an installed one.
    static var url: URL? {
        let running = runningCopies.lazy.compactMap(\.bundleURL).first
        let installed = bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        // The bundle IDs are generic enough that another app could use one.
        return ([running].compactMap { $0 } + installed).first(where: isArchon)
    }

    static var isRunning: Bool { !runningCopies.isEmpty }

    private static var runningCopies: [NSRunningApplication] {
        bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { $0.bundleURL.map(isArchon) ?? false }
    }

    private static func isArchon(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("Archon")
    }

    /// Opens the app to upload `file`. Archon must not be running, or it ignores the file.
    static func upload(_ file: URL, with app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--operation-name", "uploadALog", "--file-path", file.path]
        try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    static func activate(_ app: URL) {
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Asks each running copy to quit and waits for them to, returning false if one is still
    /// running after `timeout`.
    static func quit(timeout: Duration = .seconds(15)) async -> Bool {
        runningCopies.forEach { $0.terminate() }
        let deadline = ContinuousClock.now + timeout
        // Asks afresh each time: `isTerminated` on the copies already in hand can lag.
        while isRunning {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }
}
