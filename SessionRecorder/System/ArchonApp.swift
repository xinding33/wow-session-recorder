import AppKit

/// The Archon app, Warcraft Logs' uploader since the old Warcraft Logs Uploader retired.
///
/// It has no way to be handed a file, so uploading means opening it and choosing the file there.
enum ArchonApp {
    /// The full app first, then Archon App Lite, which only uploads logs.
    static let bundleIDs = ["archon", "archon-lite"]

    static let downloadURL = URL(string: "https://github.com/RPGLogs/Uploaders-archon-lite/releases/latest")!

    /// A running copy if there is one, otherwise an installed one.
    static var url: URL? {
        let running = bundleIDs.lazy
            .compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.bundleURL }
            .first
        let installed = bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        // The bundle IDs are generic enough that another app could use one.
        return ([running].compactMap { $0 } + installed).first { $0.lastPathComponent.hasPrefix("Archon") }
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
