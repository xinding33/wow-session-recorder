import Foundation
import Testing
@testable import RecorderCore

struct ActivityTrackerTests {
    private func replay(_ fixture: String, into tracker: inout ActivityTracker) throws -> Library {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "txt", subdirectory: "Fixtures"))
        var library = Library()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            if let entry = CombatLogParser.parse(line: line) {
                library.upsert(tracker.handle(entry))
            }
        }
        return library
    }

    @Test func mythicPlusRunBecomesOneActivityWithMarkers() throws {
        var tracker = ActivityTracker()
        let library = try replay("mythic-plus", into: &tracker)

        #expect(library.activities.count == 1)
        let key = try #require(library.activities.first)
        #expect(key.kind == .mythicPlus)
        #expect(key.title == "Algeth'ar Academy +10")
        #expect(key.subtitle == "Mythic+ · 16:57")
        #expect(key.result == .completed)
        #expect(key.markers.map(\.kind) == [.bossPull, .death, .bossKill, .playerDeath])
        #expect(key.markers.map(\.label) == ["Pull: Overgrown Ancient", "Tankyboi died", "Kill: Overgrown Ancient", "You died"])
        #expect(tracker.current == nil)
    }

    @Test func raidPullsBecomeSeparateActivities() throws {
        var tracker = ActivityTracker()
        let library = try replay("raid", into: &tracker)

        #expect(library.activities.count == 2)
        let (wipe, kill) = (library.activities[0], library.activities[1])
        #expect(wipe.kind == .raidEncounter)
        #expect(wipe.title == "Imperator Averzian")
        #expect(wipe.subtitle == "The Voidspire · Heroic")
        #expect(wipe.result == .wipe)
        #expect(wipe.duration() == 180)
        #expect(wipe.markers.map(\.kind) == [.bossPull, .death, .bossWipe])
        #expect(kill.result == .kill)
        #expect(kill.duration() == 330)
    }

    @Test func leavingTheInstanceEndsAnOpenEncounter() {
        var tracker = ActivityTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = tracker.handle(.init(date: t0, event: .zoneChange(instanceID: 1, name: "Dungeon", difficultyID: 23)))
        _ = tracker.handle(.init(date: t0, event: .encounterStart(encounterID: 9, name: "Boss", difficultyID: 23, groupSize: 5, instanceID: 1)))
        let changed = tracker.handle(.init(date: t0 + 60, event: .zoneChange(instanceID: 0, name: "Dornogal", difficultyID: 0)))

        #expect(changed.count == 1)
        #expect(changed[0].result == .unknown)
        #expect(changed[0].end == t0 + 60)
        #expect(tracker.current == nil)
    }

    @Test func leavingTheInstanceMidKeyKeepsTheKeyOpen() {
        var tracker = ActivityTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = tracker.handle(.init(date: t0, event: .zoneChange(instanceID: 5, name: "Skyreach", difficultyID: 8)))
        _ = tracker.handle(.init(date: t0, event: .challengeModeStart(zoneName: "Skyreach", instanceID: 5, challengeModeID: 1, keystoneLevel: 12)))
        let changed = tracker.handle(.init(date: t0 + 60, event: .zoneChange(instanceID: 0, name: "Outside", difficultyID: 0)))

        #expect(changed.isEmpty)
        #expect(tracker.current?.kind == .mythicPlus)
    }

    @Test func newLogFileClosesEncountersButNotKeys() {
        var tracker = ActivityTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = tracker.handle(.init(date: t0, event: .encounterStart(encounterID: 9, name: "Boss", difficultyID: 16, groupSize: 20, instanceID: 1)))
        #expect(tracker.logFileChanged(at: t0 + 10).first?.result == .unknown)

        _ = tracker.handle(.init(date: t0 + 20, event: .challengeModeStart(zoneName: "Skyreach", instanceID: 5, challengeModeID: 1, keystoneLevel: 12)))
        #expect(tracker.logFileChanged(at: t0 + 30).isEmpty)
        #expect(tracker.current?.kind == .mythicPlus)
    }

    @Test func instanceDetectionFollowsZoneChanges() {
        var tracker = ActivityTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(!tracker.wantsRecording)

        _ = tracker.handle(.init(date: t0, event: .zoneChange(instanceID: 2526, name: "Algeth'ar Academy", difficultyID: 23)))
        #expect(tracker.isInInstance && tracker.wantsRecording)

        _ = tracker.handle(.init(date: t0 + 60, event: .zoneChange(instanceID: 0, name: "Silvermoon City", difficultyID: 0)))
        #expect(!tracker.isInInstance && !tracker.wantsRecording)

        // Delves count; unknown instanced zones (e.g. housing) don't.
        _ = tracker.handle(.init(date: t0 + 120, event: .zoneChange(instanceID: 3000, name: "Delve", difficultyID: 208)))
        #expect(tracker.isInInstance)
        _ = tracker.handle(.init(date: t0 + 180, event: .zoneChange(instanceID: 3001, name: "Neighborhood", difficultyID: 999)))
        #expect(!tracker.isInInstance)
    }

    @Test func openKeyKeepsRecordingWhenSteppingOutside() {
        var tracker = ActivityTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = tracker.handle(.init(date: t0, event: .zoneChange(instanceID: 5, name: "Skyreach", difficultyID: 8)))
        _ = tracker.handle(.init(date: t0, event: .challengeModeStart(zoneName: "Skyreach", instanceID: 5, challengeModeID: 1, keystoneLevel: 12)))
        _ = tracker.handle(.init(date: t0 + 60, event: .zoneChange(instanceID: 0, name: "Outside", difficultyID: 0)))
        #expect(!tracker.isInInstance)
        #expect(tracker.wantsRecording)
    }

    @Test func seedZoneDoesNotCreateActivities() {
        var tracker = ActivityTracker()
        tracker.seedZone(from: .init(date: Date(), event: .zoneChange(instanceID: 2526, name: "Algeth'ar Academy", difficultyID: 23)))
        #expect(tracker.isInInstance)
        #expect(tracker.current == nil)
    }

    @Test func bookmarkWithoutPriorFootageRunsForward() throws {
        var tracker = ActivityTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clip = try #require(tracker.bookmark(at: t0, hasFootageBefore: false).first)
        #expect(clip.start == t0)
        #expect(clip.end == t0 + 60)
    }

    @Test func arenaResultUsesTeamID() {
        var tracker = ActivityTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = tracker.handle(.init(date: t0, event: .arenaMatchStart(instanceID: 1505, matchType: "3v3", teamID: 1)))
        let changed = tracker.handle(.init(date: t0 + 120, event: .arenaMatchEnd(winningTeam: 1, durationSeconds: 120)))

        #expect(changed.first?.title == "Arena 3v3")
        #expect(changed.first?.result == .win)
    }

    @Test func bookmarkOutsideActivityCreatesShortClip() throws {
        var tracker = ActivityTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clip = try #require(tracker.bookmark(at: t0).first)

        #expect(clip.kind == .clip)
        #expect(clip.start == t0 - 30)
        #expect(clip.end == t0 + 10)
        #expect(clip.markers.map(\.kind) == [.bookmark])
    }

    @Test func rapidBookmarksExtendOneClip() throws {
        var tracker = ActivityTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let first = try #require(tracker.bookmark(at: t0).first)
        let second = try #require(tracker.bookmark(at: t0 + 4).first)

        #expect(second.id == first.id)
        #expect(second.start == t0 - 30)
        #expect(second.end == t0 + 14)
        #expect(second.markers.count == 2)

        // Once the clip's window has passed, the next bookmark starts a new clip.
        let third = try #require(tracker.bookmark(at: t0 + 60).first)
        #expect(third.id != first.id)
    }

    @Test func bookmarkInsideActivityAddsMarker() {
        var tracker = ActivityTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = tracker.handle(.init(date: t0, event: .encounterStart(encounterID: 9, name: "Boss", difficultyID: 16, groupSize: 20, instanceID: 1)))
        let changed = tracker.bookmark(at: t0 + 5)

        #expect(changed.count == 1)
        #expect(changed[0].kind == .raidEncounter)
        #expect(changed[0].markers.last?.kind == .bookmark)
    }

    @Test func manualClipToggles() {
        var tracker = ActivityTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let started = tracker.toggleManualClip(at: t0)
        #expect(started.first?.isInProgress == true)
        let ended = tracker.toggleManualClip(at: t0 + 42)
        #expect(ended.first?.id == started.first?.id)
        #expect(ended.first?.duration() == 42)
        #expect(tracker.manualClip == nil)
    }

    @Test func upsertPreservesFavorites() {
        var library = Library()
        var activity = Activity(kind: .clip, title: "Clip", start: Date())
        library.upsert([activity])
        library.activities[0].isFavorite = true
        activity.title = "Renamed"
        library.upsert([activity])
        #expect(library.activities[0].isFavorite)
        #expect(library.activities[0].title == "Renamed")
    }
}
