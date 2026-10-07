import AppKit

/// Locates the retail WoW install (the `_retail_` folder).
enum WoWInstall {
    static let bundleID = "com.blizzard.worldofwarcraft"

    static func detectRetailFolder() -> URL? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL {
            return app.deletingLastPathComponent()
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           app.deletingLastPathComponent().lastPathComponent == "_retail_" {
            return app.deletingLastPathComponent()
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            URL(fileURLWithPath: "/Applications/World of Warcraft"),
            home.appending(path: "Applications/World of Warcraft"),
        ]
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)) ?? []
        for volume in volumes {
            candidates.append(volume.appending(path: "Applications/World of Warcraft"))
            candidates.append(volume.appending(path: "World of Warcraft"))
        }
        return candidates.lazy.compactMap(normalize).first
    }

    /// Accepts either the `World of Warcraft` folder or its `_retail_` folder.
    static func normalize(_ url: URL) -> URL? {
        let retail = url.lastPathComponent == "_retail_" ? url : url.appending(path: "_retail_")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: retail.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return retail
    }

    static func logsFolder(in retail: URL) -> URL {
        retail.appending(path: "Logs")
    }

    static func addOnsFolder(in retail: URL) -> URL {
        retail.appending(path: "Interface/AddOns")
    }
}

/// Installs the bundled WoW Session Recorder Helper addon.
enum HelperAddon {
    static let name = "SessionRecorderHelper"

    static var bundledURL: URL? {
        Bundle.main.resourceURL?.appending(path: "Addon/\(name)")
    }

    static var bundledVersion: String? {
        bundledURL.flatMap(version(in:))
    }

    static func installedVersion(retail: URL) -> String? {
        version(in: WoWInstall.addOnsFolder(in: retail).appending(path: name))
    }

    static func install(retail: URL) throws {
        guard let source = bundledURL else { throw CocoaError(.fileNoSuchFile) }
        let addOns = WoWInstall.addOnsFolder(in: retail)
        let destination = addOns.appending(path: name)
        try FileManager.default.createDirectory(at: addOns, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func version(in folder: URL) -> String? {
        let toc = folder.appending(path: "\(name).toc")
        guard let text = try? String(contentsOf: toc, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("## Version:") }
        return line.map { $0.dropFirst("## Version:".count).trimmingCharacters(in: .whitespaces) }
    }
}
