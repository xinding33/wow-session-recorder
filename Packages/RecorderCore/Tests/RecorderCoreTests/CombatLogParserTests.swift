import Foundation
import Testing
@testable import RecorderCore

struct CombatLogParserTests {
    @Test func parsesTimestampWithOffset() throws {
        let date = try #require(CombatTimestamp.parse("5/20/2026 13:31:34.075-7"))
        // 13:31:34.075 at UTC-7 is 20:31:34.075 UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        #expect(c.year == 2026 && c.month == 5 && c.day == 20)
        #expect(c.hour == 20 && c.minute == 31 && c.second == 34)
        #expect(abs(Double(c.nanosecond!) / 1e9 - 0.075) < 0.001)
    }

    @Test func parsesTimestampWithoutYearOrOffset() throws {
        let date = try #require(CombatTimestamp.parse("5/20 13:31:34.075"))
        let c = Calendar.current.dateComponents([.month, .day, .hour], from: date)
        #expect(c.month == 5 && c.day == 20 && c.hour == 13)
    }

    @Test func ignoresUninterestingEvents() {
        let line = #"5/20/2026 13:31:34.391-7  SPELL_AURA_REFRESH,Player-1-1,"A-B-US",0x512,0x80000000,Player-1-1,"A-B-US",0x512,0x80000000,462854,"Skyfury",0x8,BUFF"#
        #expect(CombatLogParser.parse(line: line) == nil)
        #expect(CombatLogParser.parse(line: "garbage") == nil)
        #expect(CombatLogParser.parse(line: "") == nil)
    }

    @Test func parsesEncounterEvents() throws {
        let start = try #require(CombatLogParser.parse(line: #"5/20/2026 13:34:18.056-7  ENCOUNTER_START,2563,"Overgrown Ancient",8,5,2526"#))
        #expect(start.event == .encounterStart(encounterID: 2563, name: "Overgrown Ancient", difficultyID: 8, groupSize: 5, instanceID: 2526))

        let end = try #require(CombatLogParser.parse(line: #"5/20/2026 13:35:33.059-7  ENCOUNTER_END,2563,"Overgrown Ancient",8,5,1,75006"#))
        #expect(end.event == .encounterEnd(encounterID: 2563, name: "Overgrown Ancient", difficultyID: 8, groupSize: 5, success: true, durationMs: 75006))
        #expect(abs(end.date.timeIntervalSince(start.date) - 75.003) < 0.001)
    }

    @Test func parsesChallengeModeEvents() throws {
        let start = try #require(CombatLogParser.parse(line: #"5/20/2026 20:45:01.993-7  CHALLENGE_MODE_START,"Skyreach",1209,161,11,[162,10,9]"#))
        #expect(start.event == .challengeModeStart(zoneName: "Skyreach", instanceID: 1209, challengeModeID: 161, keystoneLevel: 11, affixIDs: [162, 10, 9]))

        let end = try #require(CombatLogParser.parse(line: "5/20/2026 21:03:11.793-7  CHALLENGE_MODE_END,1209,1,11,1101714,347.908173,3445.950195"))
        #expect(end.event == .challengeModeEnd(instanceID: 1209, success: true, keystoneLevel: 11, durationMs: 1101714))
    }

    @Test func parsesZoneNamesContainingApostrophes() throws {
        let entry = try #require(CombatLogParser.parse(line: #"5/20/2026 13:31:34.075-7  ZONE_CHANGE,2526,"Algeth'ar Academy",23"#))
        #expect(entry.event == .zoneChange(instanceID: 2526, name: "Algeth'ar Academy", difficultyID: 23))
    }

    @Test func parsesPlayerDeaths() throws {
        let mine = try #require(CombatLogParser.parse(line: #"5/20/2026 14:30:41.151-7  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Player-3676-0EE16FAF,"Me-Area52-US",0x511,0x80000000,0"#))
        #expect(mine.event == .playerDied(guid: "Player-3676-0EE16FAF", name: "Me-Area52-US", isMine: true))

        let party = try #require(CombatLogParser.parse(line: #"5/20/2026 14:30:41.151-7  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Player-3676-0EE16FB0,"Healer-Area52-US",0x512,0x80000000,0"#))
        #expect(party.event == .playerDied(guid: "Player-3676-0EE16FB0", name: "Healer-Area52-US", isMine: false))
    }

    @Test func ignoresFeignDeathAndCreatureDeaths() {
        let feign = #"5/20/2026 13:32:58.051-7  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Player-3684-09F03BC1,"Hunter-Area52-US",0x512,0x80000000,1"#
        let creature = #"5/20/2026 13:33:01.092-7  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Creature-0-3134-2526-65829-258578-00000E1A7C,"Lesser Ghoul",0x2112,0x80000000,0"#
        #expect(CombatLogParser.parse(line: feign) == nil)
        #expect(CombatLogParser.parse(line: creature) == nil)
    }

    @Test func lineBufferHandlesCRLFAndPartialLines() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("first\r\nsec".utf8)) == ["first"])
        #expect(buffer.append(Data("ond\r".utf8)) == [])
        #expect(buffer.append(Data("\nthird\n".utf8)) == ["second", "third"])
        #expect(buffer.append(Data("Bj\u{00F6}rnbow\r\n".utf8)) == ["Bj\u{00F6}rnbow"])
    }

    @Test func splitsFieldsRespectingQuotesAndBrackets() {
        let fields = CombatLogParser.splitFields(#"A,"b, c",[1,2,(3,4)],d"#)
        #expect(fields == ["A", #""b, c""#, "[1,2,(3,4)]", "d"])
    }

    /// Set `COMBAT_LOG_PATH` to a real `WoWCombatLog-*.txt` to smoke-test the parser and tracker.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COMBAT_LOG_PATH"] != nil))
    func parsesRealLog() throws {
        let path = ProcessInfo.processInfo.environment["COMBAT_LOG_PATH"]!
        let handle = try #require(FileHandle(forReadingAtPath: path))
        var buffer = LineBuffer()
        var tracker = ActivityTracker()
        var library = Library()
        var parsed = 0
        // Read in chunks like the live tailer does, so lines straddle chunk boundaries.
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            for (line, offset) in buffer.appendWithOffsets(chunk) {
                guard let entry = CombatLogParser.parse(line: line, position: LogPosition(fileName: "log", offset: offset)) else { continue }
                parsed += 1
                library.upsert(tracker.handle(entry))
            }
        }
        print("Parsed \(parsed) interesting events into \(library.activities.count) activities:")
        for a in library.activities {
            let spec = a.specID.flatMap { GameData().spec($0)?.displayName } ?? "?"
            let health = a.bossHealthPercent.map { String(format: " boss %.0f%%", $0) } ?? ""
            print("  \(a.kind.displayName): \(a.title) [\(a.subtitle)] \(a.result.displayName)\(health) \(ActivityTracker.formatDuration(a.duration())) markers=\(a.markers.count) | \(a.character ?? "?") \(spec) group=\(a.groupSpecIDs ?? []) key=\(a.keystoneLevel.map(String.init) ?? "-") affixes=\(a.affixIDs ?? []) log=\(a.log.map { "\($0.startOffset)-\($0.endOffset.map(String.init) ?? "?")" } ?? "-")")
        }
        #expect(parsed > 0)

        let markers = library.activities.flatMap(\.markers)
        let counts = Dictionary(grouping: markers, by: \.kind).mapValues(\.count)
        print("Markers by kind: \(counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " "))")

        // Death recaps, read back from the file both from the marker's position and by
        // searching for its timestamp; both must agree.
        let url = URL(fileURLWithPath: path)
        for death in markers.filter({ $0.kind == .playerDeath }) {
            let guid = try #require(death.unitGUID)
            let from = death.date.addingTimeInterval(-DeathRecap.window)
            let to = death.date.addingTimeInterval(1)
            let start = Date()
            let anchored = try CombatLogFiles.lines(in: url, anchor: death.log?.offset, from: from, to: to)
            let anchoredTime = Date().timeIntervalSince(start)
            let searched = try CombatLogFiles.lines(in: url, anchor: nil, from: from, to: to)
            let recap = DeathRecap.build(lines: anchored, unitGUID: guid, death: death.date)
            #expect(recap == DeathRecap.build(lines: searched, unitGUID: guid, death: death.date))
            #expect(!recap.events.isEmpty)
            print("Death at \(death.date) (\(anchored.count) lines read in \(String(format: "%.3f", anchoredTime)) s):")
            for e in recap.events {
                let hp = e.healthPercent.map { String(format: "%3.0f%%", $0) } ?? "   ?"
                print("  \(String(format: "%5.1f", e.date.timeIntervalSince(death.date)))s \(hp) \(e.kind == .heal ? "+" : "-")\(e.amount) \(e.ability) (\(e.source))\(e.overkill > 0 ? " overkill \(e.overkill)" : "")")
            }
        }
    }
}
