import Foundation
import Testing
@testable import RecorderCore

struct LibraryFilterTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// Noon on 2026-10-06, Pacific.
    private var t0: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))! }
    private let gameData = GameData(keystones: [402: .init(name: "Algeth'ar Academy", timeLimit: 1800)])

    private func key(level: Int, timeMs: Int?, result: ActivityResult = .completed, daysAgo: Int = 0) -> Activity {
        let start = t0 - Double(daysAgo) * 86_400
        var key = Activity(kind: .mythicPlus, title: "Algeth'ar Academy +\(level)", subtitle: "Mythic+",
                           start: start, end: start + 1000, result: result)
        key.instanceName = "Algeth'ar Academy"
        key.challengeModeID = 402
        key.keystoneLevel = level
        key.keyTimeMs = timeMs
        key.character = "Leafwhisper"
        return key
    }

    private func pull(_ boss: String, id: Int, result: ActivityResult, zone: String = "The Voidspire",
                      character: String = "Stabbington", daysAgo: Int = 0) -> Activity {
        let start = t0 - Double(daysAgo) * 86_400
        var pull = Activity(kind: .raidEncounter, title: boss, subtitle: "\(zone) · Heroic",
                            start: start, end: start + 120, result: result)
        pull.instanceName = zone
        pull.encounterID = id
        pull.difficultyID = 15
        pull.character = character
        return pull
    }

    private var library: [Activity] {
        var timed = key(level: 10, timeMs: 1_200_000)
        timed.notes = "Good route, skip the second pack"
        var bookmark = Activity(kind: .clip, title: "Bookmark", subtitle: "Silvermoon City",
                                start: t0 - 40 * 86_400, end: t0 - 40 * 86_400 + 50, result: .unknown, isFavorite: true)
        bookmark.instanceName = "Silvermoon City"
        return [
            timed,
            key(level: 12, timeMs: 1_900_000, daysAgo: 1),
            key(level: 15, timeMs: nil, result: .abandoned, daysAgo: 3),
            pull("Imperator Averzian", id: 3176, result: .wipe),
            pull("Imperator Averzian", id: 3176, result: .kill, daysAgo: 1),
            pull("Vorasius", id: 3177, result: .wipe, daysAgo: 8),
            bookmark,
        ]
    }

    private func titles(_ filter: ActivityFilter) -> [String] {
        filter.apply(library, gameData: gameData, calendar: calendar).map(\.title)
    }

    @Test func emptyFilterShowsEverything() {
        let filter = ActivityFilter()
        #expect(titles(filter).count == library.count)
        #expect(!filter.isNarrowed)
        #expect(filter.activeFilterCount == 0)
    }

    @Test func searchMatchesEveryWordInTitleSubtitleOrNotes() {
        var filter = ActivityFilter()
        filter.text = "  averzian  "
        #expect(titles(filter) == ["Imperator Averzian", "Imperator Averzian"])
        filter.text = "voidspire VORASIUS"
        #expect(titles(filter) == ["Vorasius"])
        // Notes, ignoring case and accents.
        filter.text = "ROUTE sécond"
        #expect(titles(filter) == ["Algeth'ar Academy +10"])
        filter.text = "averzian vorasius"
        #expect(titles(filter).isEmpty)
        #expect(filter.isNarrowed)
        #expect(filter.activeFilterCount == 0)
    }

    @Test func filtersByInstanceOrBoss() {
        var filter = ActivityFilter()
        filter.place = .instance("The Voidspire")
        #expect(titles(filter) == ["Imperator Averzian", "Imperator Averzian", "Vorasius"])
        filter.place = .boss(encounterID: 3177)
        #expect(titles(filter) == ["Vorasius"])
        filter.place = .instance("Algeth'ar Academy")
        #expect(titles(filter).count == 3)
        #expect(filter.activeFilterCount == 1)
    }

    @Test func filtersByResultIncludingTimedAndDepleted() {
        var filter = ActivityFilter()
        filter.outcomes = [.timed]
        #expect(titles(filter) == ["Algeth'ar Academy +10"])
        filter.outcomes = [.depleted]
        #expect(titles(filter) == ["Algeth'ar Academy +12"])
        filter.outcomes = [.completed]
        #expect(titles(filter) == ["Algeth'ar Academy +10", "Algeth'ar Academy +12"])
        filter.outcomes = [.abandoned, .kill]
        #expect(titles(filter) == ["Algeth'ar Academy +15", "Imperator Averzian"])
        filter.outcomes = [.wipe]
        #expect(titles(filter) == ["Imperator Averzian", "Vorasius"])
        // Without the addon's timers a key is neither timed nor depleted.
        filter.outcomes = [.timed, .depleted]
        #expect(filter.apply(library, gameData: GameData(), calendar: calendar).isEmpty)
    }

    @Test func filtersByKeyLevelRange() {
        var filter = ActivityFilter()
        filter.minKeyLevel = 11
        #expect(titles(filter) == ["Algeth'ar Academy +12", "Algeth'ar Academy +15"])
        filter.maxKeyLevel = 12
        #expect(titles(filter) == ["Algeth'ar Academy +12"])
        filter.minKeyLevel = nil
        #expect(titles(filter) == ["Algeth'ar Academy +10", "Algeth'ar Academy +12"])
    }

    @Test func filtersByDayRangeInclusive() {
        var filter = ActivityFilter()
        let (from, to) = ActivityFilter.DatePreset.last7Days.days(now: t0, calendar: calendar)
        filter.fromDay = from
        filter.toDay = to
        #expect(titles(filter).count == 5)
        // A single day, picked at any time of day, covers all of it.
        filter.fromDay = t0 - 86_400 + 3600 * 11
        filter.toDay = t0 - 86_400 - 3600 * 11
        #expect(titles(filter) == ["Algeth'ar Academy +12", "Imperator Averzian"])
        let today = ActivityFilter.DatePreset.today.days(now: t0, calendar: calendar)
        #expect(today.from == today.to)
        #expect(today.from == calendar.startOfDay(for: t0))
    }

    @Test func filtersByCharacterAndSidebar() {
        var filter = ActivityFilter()
        filter.character = "Stabbington"
        #expect(titles(filter).count == 3)
        filter.character = nil
        filter.favoritesOnly = true
        #expect(titles(filter) == ["Bookmark"])
        filter.favoritesOnly = false
        filter.kind = .mythicPlus
        filter.outcomes = [.completed]
        #expect(titles(filter).count == 2)
        // Clearing keeps the sidebar choice.
        filter.clear()
        #expect(filter.kind == .mythicPlus)
        #expect(titles(filter).count == 3)
    }

    @Test func facetsListInstancesBossesCharactersAndKeyLevels() {
        let facets = LibraryFacets(library)
        #expect(facets.instances.map(\.name) == ["Algeth'ar Academy", "The Voidspire", "Silvermoon City"])
        #expect(facets.instances.map(\.group) == [.dungeons, .raids, .other])
        #expect(facets.instances[1].bosses.map(\.name) == ["Imperator Averzian", "Vorasius"])
        #expect(facets.instances[0].bosses.isEmpty)
        #expect(facets.characters == ["Leafwhisper", "Stabbington"])
        #expect(facets.keyLevels == 10...15)
        #expect(facets.name(of: .boss(encounterID: 3177)) == "Vorasius")
        #expect(facets.name(of: .instance("The Voidspire")) == "The Voidspire")
    }

    @Test func instanceNamesForOlderActivitiesComeFromTitles() {
        let t = t0
        func old(_ kind: ActivityKind, _ title: String, _ subtitle: String, difficulty: Int? = nil) -> String? {
            var activity = Activity(kind: kind, title: title, subtitle: subtitle, start: t)
            activity.difficultyID = difficulty
            return LibraryFacets.instanceName(of: activity)
        }
        #expect(old(.mythicPlus, "Algeth'ar Academy +10", "Mythic+ · 16:57") == "Algeth'ar Academy")
        #expect(old(.delve, "The Darkway", "Delve · 10:28") == "The Darkway")
        #expect(old(.delve, "Infiltrator Gulkat", "The Darkway · Delve") == "The Darkway")
        #expect(old(.raidEncounter, "Vorasius", "The Voidspire · Heroic") == "The Voidspire")
        #expect(old(.raidEncounter, "Vorasius", "Heroic", difficulty: 15) == nil)
        #expect(old(.clip, "Bookmark", "Silvermoon City") == "Silvermoon City")
        #expect(old(.clip, "Bookmark", "") == nil)
        // A trimmed clip's subtitle is its source's, which isn't a place.
        #expect(old(.clip, "Algeth'ar Academy +10 (clip)", "Mythic+ · 16:57") == nil)
    }

    @Test func clipsKeepTheirInstance() {
        let clip = library[3].clip(from: t0 + 10, to: t0 + 20)
        #expect(clip.instanceName == "The Voidspire")
        #expect(clip.encounterID == nil)
    }
}

struct ThumbnailTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let dir = URL(fileURLWithPath: "/tmp/segments")

    private func segment(_ from: TimeInterval, _ to: TimeInterval) -> Segment {
        Segment(url: dir.appending(path: SegmentNaming.finalName(start: t0 + from, end: t0 + to)), start: t0 + from, end: t0 + to)
    }

    @Test func momentIsAFewSecondsIntoTheFight() {
        let pull = Activity(kind: .raidEncounter, title: "Boss", start: t0, end: t0 + 120, result: .wipe)
        #expect(Thumbnails.moment(for: pull) == t0 + 5)
        // Too short for that: the middle.
        let short = Activity(kind: .raidEncounter, title: "Boss", start: t0, end: t0 + 4, result: .wipe)
        #expect(Thumbnails.moment(for: short) == t0 + 2)
        // Nothing to show until it's finished.
        #expect(Thumbnails.moment(for: Activity(kind: .raidEncounter, title: "Boss", start: t0)) == nil)
    }

    @Test func runsShowTheirFirstBossAndBookmarksTheirMoment() {
        let key = Activity(kind: .mythicPlus, title: "Key", start: t0, end: t0 + 1800, result: .completed,
                           markers: [Marker(date: t0 + 60, kind: .death, label: "x"),
                                     Marker(date: t0 + 300, kind: .bossPull, label: "Pull: A"),
                                     Marker(date: t0 + 900, kind: .bossPull, label: "Pull: B")])
        #expect(Thumbnails.moment(for: key) == t0 + 305)
        let noBoss = Activity(kind: .delve, title: "Delve", start: t0, end: t0 + 600, result: .abandoned)
        #expect(Thumbnails.moment(for: noBoss) == t0 + 5)
        let bookmark = Activity(kind: .clip, title: "Bookmark", start: t0, end: t0 + 50, result: .unknown,
                                markers: [Marker(date: t0 + 40, kind: .bookmark, label: "Bookmark")])
        #expect(Thumbnails.moment(for: bookmark) == t0 + 37)
    }

    @Test func sourceFindsTheSegmentOrTheFirstFootageInside() throws {
        let pull = Activity(kind: .raidEncounter, title: "Boss", start: t0 + 50, end: t0 + 200, result: .kill)
        let first = try #require(Thumbnails.source(for: pull, segments: [segment(0, 60), segment(60, 120)], footageEnd: t0 + 120))
        #expect(first.url == segment(0, 60).url)
        #expect(first.time == 55)
        let later = Activity(kind: .raidEncounter, title: "Boss", start: t0 + 58, end: t0 + 200, result: .kill)
        let second = try #require(Thumbnails.source(for: later, segments: [segment(0, 60), segment(60, 120)], footageEnd: t0 + 120))
        #expect(second.url == segment(60, 120).url)
        #expect(second.time == 3)
        // Recording was paused at the moment; use the first footage inside the activity instead.
        let gap = try #require(Thumbnails.source(for: pull, segments: [segment(0, 52), segment(150, 210)], footageEnd: t0 + 210))
        #expect(gap.url == segment(0, 52).url)
        #expect(gap.time == 51)
        #expect(Thumbnails.source(for: pull, segments: [segment(300, 360)], footageEnd: t0 + 360) == nil)
    }

    @Test func sourceWaitsForFootageStillBeingRecorded() throws {
        // Bookmarked 20 s into a segment that's still recording: don't settle for the one before.
        let bookmark = Activity(kind: .clip, title: "Bookmark", start: t0 + 40, end: t0 + 90, result: .unknown,
                                markers: [Marker(date: t0 + 80, kind: .bookmark, label: "Bookmark")])
        #expect(Thumbnails.source(for: bookmark, segments: [segment(0, 60)], footageEnd: t0 + 60) == nil)
        let later = try #require(Thumbnails.source(for: bookmark, segments: [segment(0, 60), segment(60, 120)], footageEnd: t0 + 120))
        #expect(later.url == segment(60, 120).url)
        #expect(later.time == 17)
    }

    @Test func orphanedFilesAreThoseWithoutAnActivity() {
        let kept = UUID(), gone = UUID()
        let names = [Thumbnails.fileName(for: kept), Thumbnails.fileName(for: gone), ".DS_Store", "notes.jpg"]
        #expect(Thumbnails.orphans(fileNames: names, keeping: [kept]) == [Thumbnails.fileName(for: gone)])
        #expect(Thumbnails.activityID(fromFileName: Thumbnails.fileName(for: kept)) == kept)
    }
}
