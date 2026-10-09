import Foundation
import Testing
@testable import RecorderCore

/// Each test uses its own pair of throwaway preference domains.
@Suite(.serialized)
struct LegacyBundleTests {
    private let oldDomain = "test.recordercore.legacy.\(UUID().uuidString)"
    private let newDomain = "test.recordercore.current.\(UUID().uuidString)"

    private func withDefaults(_ body: (UserDefaults, UserDefaults) throws -> Void) rethrows {
        let old = UserDefaults(suiteName: oldDomain)!
        let new = UserDefaults(suiteName: newDomain)!
        defer {
            old.removePersistentDomain(forName: oldDomain)
            new.removePersistentDomain(forName: newDomain)
        }
        try body(old, new)
    }

    @Test func copiesOldSettings() {
        withDefaults { old, new in
            old.set("/Volumes/Games/Footage", forKey: "recordingsPath")
            old.set("withWoW", forKey: "launchMode")
            old.set(["/Applications/CurseForge.app"], forKey: "companionAppPaths")
            old.set(true, forKey: "hasLaunchedBefore")

            #expect(LegacyBundle.migrateSettings(from: oldDomain, to: newDomain, in: new) == 4)
            #expect(new.string(forKey: "recordingsPath") == "/Volumes/Games/Footage")
            #expect(new.string(forKey: "launchMode") == "withWoW")
            #expect(new.stringArray(forKey: "companionAppPaths") == ["/Applications/CurseForge.app"])
            #expect(new.bool(forKey: "hasLaunchedBefore"))
            // The old build's settings are left alone.
            #expect(old.string(forKey: "recordingsPath") == "/Volumes/Games/Footage")
        }
    }

    @Test func keepsSettingsAlreadySavedUnderTheNewIdentifier() {
        withDefaults { old, new in
            old.set("always", forKey: "recordingScope")
            old.set(12, forKey: "keepUnmarkedHours")
            new.set("instancesOnly", forKey: "recordingScope")

            #expect(LegacyBundle.migrateSettings(from: oldDomain, to: newDomain, in: new) == 1)
            #expect(new.string(forKey: "recordingScope") == "instancesOnly")
            #expect(new.integer(forKey: "keepUnmarkedHours") == 12)
        }
    }

    @Test func runsOnce() {
        withDefaults { old, new in
            old.set("/Applications/World of Warcraft/_retail_", forKey: "wowRetailPath")
            LegacyBundle.migrateSettings(from: oldDomain, to: newDomain, in: new)
            // Clearing a setting later mustn't bring the old value back.
            new.removeObject(forKey: "wowRetailPath")

            #expect(LegacyBundle.migrateSettings(from: oldDomain, to: newDomain, in: new) == 0)
            #expect(new.string(forKey: "wowRetailPath") == nil)
        }
    }

    @Test func freshInstallHasNothingToCopy() {
        withDefaults { _, new in
            #expect(LegacyBundle.migrateSettings(from: oldDomain, to: newDomain, in: new) == 0)
            #expect(new.bool(forKey: LegacyBundle.migratedKey))
        }
    }
}
