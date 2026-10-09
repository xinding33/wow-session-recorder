import Foundation

/// What builds made before releases were signed with a Developer ID left behind under their
/// old bundle identifier, and the one-time move of their settings to the current one.
public enum LegacyBundle {
    public static let identifier = "io.github.wowsessionrecorder.SessionRecorder"
    public static let launchAgentLabel = "io.github.wowsessionrecorder.open-with-wow"

    static let migratedKey = "migratedLegacySettings"

    /// Copies settings saved under `oldDomain` into `defaults`, whose own domain is `newDomain`.
    /// Settings already saved under the new identifier win. Runs once, so settings cleared
    /// later aren't brought back. Returns how many settings were copied.
    @discardableResult
    public static func migrateSettings(from oldDomain: String = identifier, to newDomain: String,
                                       in defaults: UserDefaults) -> Int {
        guard !defaults.bool(forKey: migratedKey) else { return 0 }
        let current = defaults.persistentDomain(forName: newDomain) ?? [:]
        var copied = 0
        for (key, value) in defaults.persistentDomain(forName: oldDomain) ?? [:] where current[key] == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(true, forKey: migratedKey)
        return copied
    }
}
