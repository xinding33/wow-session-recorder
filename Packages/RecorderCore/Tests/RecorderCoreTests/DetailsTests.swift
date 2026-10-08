import Foundation
import Testing
@testable import RecorderCore

/// Character, spec, boss health, key details and log positions read from the combat log.
struct DetailsTests {
    // Real lines from a delve log; only the player name is changed.
    private let combatantInfo = #"10/6/2026 23:07:24.400-7  COMBATANT_INFO,Player-3676-0EDE9128,0,270,617,43031,3232,0,0,0,0,962,962,962,115,61,631,631,631,479,753,404,404,404,1523,264,[(80976,101842,1),(81018,101895,1)],(0,0,0,0),[]"#
    private let ownCast = #"10/6/2026 22:58:53.023-7  SPELL_CAST_SUCCESS,Player-3676-0EDE9128,"Leafwhisper-Area52-US",0x511,0x80000000,0000000000000000,nil,0x80000000,0x80000000,2645,"Ghost Wolf",0x8,Player-3676-0EDE9128,0000000000000000,860620,860620,1042,3138,1523,750,1241,0,0,260000,260000,0,3542.00,4802.26,2525,2.9057,319"#
    private let bossSwing = #"10/6/2026 23:07:29.245-7  SWING_DAMAGE,Creature-0-3782-3003-21320-251600-000045E16F,"Infiltrator Gulkat",0x10a48,0x80000000,Creature-0-3782-3003-21320-248567-000045E14F,"Valeera Sanguinar",0x2111,0x80000000,Creature-0-3782-3003-21320-251600-000045E16F,0000000000000000,6456394,6860717,0,0,1470,0,0,0,0,10312,10312,0,3117.42,4806.54,2525,2.6753,92,15651,17556,-1,1,0,0,0,nil,nil,nil"#
    private let bossCast = #"10/6/2026 23:07:33.446-7  SPELL_CAST_SUCCESS,Creature-0-3782-3003-21320-251600-000045E16F,"Infiltrator Gulkat",0x10a48,0x80000000,0000000000000000,nil,0x80000000,0x80000000,1272820,"Abyssal Burst",0x20,Creature-0-3782-3003-21320-251600-000045E16F,0000000000000000,4422777,6860717,0,0,1470,0,0,0,0,10312,10312,0,3117.42,4806.54,2525,6.1193,92"#
    private let friendlyNPCSwing = #"10/6/2026 23:07:40.164-7  SWING_DAMAGE,Creature-0-3782-3003-21320-248567-000045E14F,"Valeera Sanguinar",0x2111,0x80000000,Creature-0-3782-3003-21320-251600-000045E16F,"Infiltrator Gulkat",0x10a48,0x80000000,Creature-0-3782-3003-21320-248567-000045E14F,Player-3676-0EDE9128,860620,860620,7598,7598,1690,0,0,0,3,100,100,0,3116.97,4807.49,2525,4.5704,319,101016,70734,-1,1,0,0,0,1,nil,nil"#

    // MARK: Parser

    @Test func parsesSpecFromCombatantInfo() throws {
        let entry = try #require(CombatLogParser.parse(line: combatantInfo))
        #expect(entry.event == .combatantInfo(guid: "Player-3676-0EDE9128", specID: 264))
    }

    @Test func parsesOwnCasts() throws {
        let entry = try #require(CombatLogParser.parse(line: ownCast))
        #expect(entry.event == .ownCast(guid: "Player-3676-0EDE9128", name: "Leafwhisper-Area52-US", spellID: 2645, spellName: "Ghost Wolf"))
    }

    @Test func parsesHostileHealthFromBossActions() throws {
        let swing = try #require(CombatLogParser.parse(line: bossSwing))
        #expect(swing.event == .hostileHealth(guid: "Creature-0-3782-3003-21320-251600-000045E16F", current: 6456394, max: 6860717))
        let cast = try #require(CombatLogParser.parse(line: bossCast))
        #expect(cast.event == .hostileHealth(guid: "Creature-0-3782-3003-21320-251600-000045E16F", current: 4422777, max: 6860717))
        // A friendly NPC's swing reports its own health, which isn't a boss's.
        #expect(CombatLogParser.parse(line: friendlyNPCSwing) == nil)
    }

    @Test func lineBufferReportsByteOffsets() {
        var buffer = LineBuffer(startOffset: 100)
        let first = buffer.appendWithOffsets(Data("ab\r\ncd".utf8))
        #expect(first.map(\.line) == ["ab"])
        #expect(first.map(\.offset) == [100])
        let second = buffer.appendWithOffsets(Data("e\r\nf\n".utf8))
        #expect(second.map(\.line) == ["cde", "f"])
        #expect(second.map(\.offset) == [104, 109])
    }

    // MARK: Tracker

    private func feed(_ lines: [String], file: String = "log.txt") -> (ActivityTracker, Library) {
        var tracker = ActivityTracker()
        var library = Library()
        var offset: UInt64 = 0
        for line in lines {
            if let entry = CombatLogParser.parse(line: line, position: LogPosition(fileName: file, offset: offset)) {
                library.upsert(tracker.handle(entry))
            }
            offset += UInt64(line.utf8.count + 2)
        }
        return (tracker, library)
    }

    @Test func activityRecordsCharacterSpecAndGroup() throws {
        let (_, library) = feed([
            ownCast,
            #"10/6/2026 23:07:24.400-7  ENCOUNTER_START,3361,"Infiltrator Gulkat",16,20,3003"#,
            combatantInfo,
            #"10/6/2026 23:07:24.401-7  COMBATANT_INFO,Player-1-2,0,1,1,1,1,0,0,0,0,1,1,1,0,0,1,1,1,0,1,1,1,1,1,105,[]"#,
            #"10/6/2026 23:08:00.000-7  ENCOUNTER_END,3361,"Infiltrator Gulkat",16,20,1,36000"#,
        ])
        let pull = try #require(library.activities.first)
        #expect(pull.character == "Leafwhisper")
        #expect(pull.specID == 264)
        #expect(pull.groupSpecIDs == [105, 264])
        #expect(pull.encounterID == 3361)
        #expect(pull.difficultyID == 16)
    }

    @Test func wipeRecordsLowestBossHealth() throws {
        let (_, library) = feed([
            #"10/6/2026 23:07:24.400-7  ENCOUNTER_START,3361,"Infiltrator Gulkat",16,20,3003"#,
            bossSwing,
            bossCast,
            friendlyNPCSwing,
            // After the wipe the boss resets to full; the lowest point is what counts.
            bossSwing,
            #"10/6/2026 23:08:00.000-7  ENCOUNTER_END,3361,"Infiltrator Gulkat",16,20,0,36000"#,
        ])
        let pull = try #require(library.activities.first)
        #expect(pull.result == .wipe)
        let health = try #require(pull.bossHealthPercent)
        #expect(abs(health - 64.46) < 0.01)
        #expect(pull.markers.last?.label == "Wipe: Infiltrator Gulkat (64%)")
    }

    @Test func killHasNoBossHealth() throws {
        let (_, library) = feed([
            #"10/6/2026 23:07:24.400-7  ENCOUNTER_START,3361,"Infiltrator Gulkat",16,20,3003"#,
            bossCast,
            #"10/6/2026 23:08:00.000-7  ENCOUNTER_END,3361,"Infiltrator Gulkat",16,20,1,36000"#,
        ])
        #expect(library.activities.first?.bossHealthPercent == nil)
        #expect(library.activities.first?.markers.last?.label == "Kill: Infiltrator Gulkat")
    }

    @Test func keyRecordsLevelAffixesAndTime() throws {
        let (_, library) = feed([
            #"5/20/2026 20:45:01.993-7  CHALLENGE_MODE_START,"Skyreach",1209,161,11,[162,10,9]"#,
            "5/20/2026 21:03:11.793-7  CHALLENGE_MODE_END,1209,1,11,1101714,347.908173,3445.950195",
        ])
        let key = try #require(library.activities.first)
        #expect(key.challengeModeID == 161)
        #expect(key.keystoneLevel == 11)
        #expect(key.affixIDs == [162, 10, 9])
        #expect(key.keyTimeMs == 1101714)
    }

    @Test func activityRemembersItsLogRange() throws {
        let lines = [
            #"10/6/2026 22:58:30.333-7  ZONE_CHANGE,3003,"The Darkway",208"#,
            ownCast,
            #"10/6/2026 23:08:58.827-7  ZONE_CHANGE,0,"Silvermoon City",0"#,
        ]
        let (_, library) = feed(lines, file: "WoWCombatLog-100626_225830.txt")
        let run = try #require(library.activities.first)
        let endOffset = UInt64(lines[0].utf8.count + 2 + lines[1].utf8.count + 2)
        #expect(run.log == LogRange(fileName: "WoWCombatLog-100626_225830.txt", startOffset: 0, endOffset: endOffset))
    }

    // MARK: Game data

    @Test func keystoneOutcomeThresholds() {
        #expect(KeystoneOutcome(keyTimeMs: 1_000_000, timeLimit: 1800) == .timed(upgrade: 3))
        #expect(KeystoneOutcome(keyTimeMs: 1_300_000, timeLimit: 1800) == .timed(upgrade: 2))
        #expect(KeystoneOutcome(keyTimeMs: 1_700_000, timeLimit: 1800) == .timed(upgrade: 1))
        #expect(KeystoneOutcome(keyTimeMs: 1_900_000, timeLimit: 1800) == .depleted)
    }

    @Test func parsesSavedVariablesAsWoWWritesThem() throws {
        let text = #"""

        SessionRecorderHelperDB = {
        ["mode"] = "instances",
        ["gameData"] = {
        ["keystones"] = {
        [402] = {
        ["timeLimit"] = 1800,
        ["name"] = "Algeth'ar Academy",
        },
        [161] = {
        ["timeLimit"] = 1680,
        ["name"] = "Sky\"reach\\",
        },
        },
        ["affixes"] = {
        [10] = "Fortified",
        [9] = "Tyrannical",
        },
        ["specs"] = {
        [264] = {
        ["spec"] = "Restoration",
        ["class"] = "Shaman",
        },
        },
        ["list"] = {
        "a", -- [1]
        "b", -- [2]
        },
        ["flag"] = true,
        ["ratio"] = -0.5,
        },
        }
        OtherDB = nil
        """#
        let vars = LuaSavedVariables.parse(text)
        let db = try #require(vars["SessionRecorderHelperDB"])
        #expect(db["mode"]?.stringValue == "instances")
        #expect(db["gameData"]?["list"]?.entries.map(\.value) == [.string("a"), .string("b")])
        #expect(db["gameData"]?["flag"] == .bool(true))
        #expect(db["gameData"]?["ratio"] == .number(-0.5))

        let data = GameData(savedVariables: db)
        #expect(data.keystones[402] == GameData.Keystone(name: "Algeth'ar Academy", timeLimit: 1800))
        #expect(data.keystones[161]?.name == #"Sky"reach\"#)
        #expect(data.affixes == [10: "Fortified", 9: "Tyrannical"])
        #expect(data.spec(264)?.displayName == "Restoration Shaman")
    }

    @Test func builtInSpecNamesCoverTheGapBeforeTheAddonRuns() {
        #expect(GameData().spec(264)?.displayName == "Restoration Shaman")
        #expect(GameData().spec(254)?.displayName == "Marksmanship Hunter")
        #expect(GameData().spec(99999) == nil)
    }
}
