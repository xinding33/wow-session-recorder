import AppKit

/// Other apps the player opens alongside WoW.
///
/// Apps are matched by location rather than bundle ID because some don't declare one.
enum CompanionApps {
    static func displayName(for url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    static func runningInstances(of url: URL) -> [NSRunningApplication] {
        let target = url.standardizedFileURL
        return NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == target }
    }

    /// Opens each app that isn't already running, without pulling focus away from WoW.
    static func open(_ urls: [URL]) {
        for url in urls where runningInstances(of: url).isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    /// Asks each app to quit normally, so it can save and clean up.
    static func quit(_ urls: [URL]) {
        for url in urls {
            runningInstances(of: url).forEach { $0.terminate() }
        }
    }
}
