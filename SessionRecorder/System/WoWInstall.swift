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

    enum Status: Equatable {
        case notInstalled
        /// Installed, but WoW hasn't loaded it yet (log in once to activate it).
        case notLoadedYet
        /// Turned off in WoW's addon list.
        case disabled
        case active
    }

    /// Whether the helper is installed and actually running in game.
    ///
    /// WoW writes `SavedVariables/SessionRecorderHelper.lua` once the addon has loaded, and
    /// records addons turned off in a character's `AddOns.txt` (only rewritten when that list
    /// changes, so the newest one reflects the most recent change).
    static func status(retail: URL) -> Status {
        guard installedVersion(retail: retail) != nil else { return .notInstalled }
        let accounts = retail.appending(path: "WTF/Account")
        let fm = FileManager.default
        var newestAddOnsList: (url: URL, modified: Date)?
        var hasLoaded = false
        for account in (try? fm.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil)) ?? [] {
            if fm.fileExists(atPath: account.appending(path: "SavedVariables/\(name).lua").path) {
                hasLoaded = true
            }
            for realm in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for character in (try? fm.contentsOfDirectory(at: realm, includingPropertiesForKeys: nil)) ?? [] {
                    let list = character.appending(path: "AddOns.txt")
                    guard let modified = try? list.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    else { continue }
                    if modified > newestAddOnsList?.modified ?? .distantPast {
                        newestAddOnsList = (list, modified)
                    }
                }
            }
        }
        if let list = newestAddOnsList?.url,
           let text = try? String(contentsOf: list, encoding: .utf8),
           text.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("\(name): disabled") }) {
            return .disabled
        }
        return hasLoaded ? .active : .notLoadedYet
    }

    /// The helper's most recently written SavedVariables file across WoW accounts.
    static func savedVariablesURL(retail: URL) -> URL? {
        let accounts = retail.appending(path: "WTF/Account")
        let files = ((try? FileManager.default.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appending(path: "SavedVariables/\(name).lua") }
            .compactMap { url -> (URL, Date)? in
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (url, modified)
            }
        return files.max { $0.1 < $1.1 }?.0
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
