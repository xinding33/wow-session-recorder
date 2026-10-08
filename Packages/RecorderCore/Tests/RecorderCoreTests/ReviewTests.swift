import Foundation
import Testing
@testable import RecorderCore

/// Review features: extra markers, death recaps, notes and trimmed clips.
struct ReviewTests {
    // Real lines from a Mythic+ log. Player names, a few times and some flags are changed.
    private let keyStart = #"5/20/2026 14:20:00.000-7  CHALLENGE_MODE_START,"Priory of the Sacred Flame",2649,499,10,[162,10,9]"#
    private let ownInterrupt = #"5/20/2026 14:21:53.513-7  SPELL_INTERRUPT,Player-3676-0EA2F4F1,"Mebear-Area52-US",0x511,0x80000020,Creature-0-3134-2526-65829-196548-00000E1AE8,"Ancient Branch",0xa48,0x80000000,93985,"Skull Bash",0x1,396640,"Healing Touch",8"#
    private let groupInterrupt = #"5/20/2026 14:21:36.960-7  SPELL_INTERRUPT,Player-3684-09F03BC1,"Bowfriend-Mal'Ganis-US",0x512,0x80000000,Creature-0-3134-2526-65829-196045-00050E1A45,"Corrupted Manafiend",0xa48,0x80000000,147362,"Counter Shot",0x1,388862,"Surge",64"#
    private let petInterrupt = #"5/20/2026 14:21:57.933-7  SPELL_INTERRUPT,Pet-0-4225-2805-18648-417-0101F524D3,"Khuudom",0x1111,0x80000000,Creature-0-4225-2805-18648-232070-00008E1F90,"Restless Steward",0xa48,0x80000000,19647,"Spell Lock",0x20,1216135,"Spirit Bolt",32"#
    private let ownDispel = #"5/20/2026 14:22:39.661-7  SPELL_DISPEL,Player-3676-0EE3DC38,"Memonk-Area52-US",0x511,0x80000000,Player-3676-0EE3DC39,"Friend-Area52-US",0x512,0x80000000,115450,"Detox",0x8,374350,"Energy Bomb",64,DEBUFF"#
    private let lust = #"5/20/2026 14:22:57.167-7  SPELL_CAST_SUCCESS,Player-3676-09823A65,"Shamfriend-Area52-US",0x512,0x80000000,0000000000000000,nil,0x80000000,0x80000000,2825,"Bloodlust",0x8,Player-3676-09823A65,0000000000000000,498000,498000,864,2632,2225,718,51,0,11,118,150,0,5052.11,-3172.31,2497,0.5110,286"#
    private let battleRes = #"5/20/2026 14:30:47.540-7  SPELL_RESURRECT,Player-1425-0EB3F12B,"Lockfriend-Drakkari-US",0x512,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,20484,"Rebirth",0x8"#
    private let normalRes = #"5/20/2026 14:31:47.540-7  SPELL_RESURRECT,Player-1425-0EB3F12B,"Lockfriend-Drakkari-US",0x512,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,2006,"Resurrection",0x2"#
    private let ownCooldown = #"5/20/2026 14:23:10.000-7  SPELL_CAST_SUCCESS,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,0000000000000000,nil,0x80000000,0x80000000,33891,"Incarnation: Tree of Life",0x8,Player-3676-0EE16FAF,0000000000000000,384680,384680,2294,2206,782,1066,320,0,0,180645,260000,0,5071.26,-3165.49,2497,1.6807,269"#

    // MARK: Parser

    @Test func parsesReviewEvents() throws {
        #expect(CombatLogParser.parse(line: ownInterrupt)?.event
                == .interrupt(spellName: "Skull Bash", interruptedSpell: "Healing Touch", targetName: "Ancient Branch"))
        // Only your own (and your pet's) interrupts are marked.
        #expect(CombatLogParser.parse(line: groupInterrupt) == nil)
        #expect(CombatLogParser.parse(line: petInterrupt)?.event
                == .interrupt(spellName: "Spell Lock", interruptedSpell: "Spirit Bolt", targetName: "Restless Steward"))
        #expect(CombatLogParser.parse(line: ownDispel)?.event
                == .dispel(spellName: "Detox", auraName: "Energy Bomb", targetName: "Friend-Area52-US", targetIsHostile: false))
        #expect(CombatLogParser.parse(line: lust)?.event == .bloodlust(sourceName: "Shamfriend-Area52-US", spellName: "Bloodlust"))
        #expect(CombatLogParser.parse(line: battleRes)?.event
                == .resurrect(sourceName: "Lockfriend-Drakkari-US", targetName: "Medruid-Area52-US", spellID: 20484, spellName: "Rebirth"))
        #expect(CombatLogParser.parse(line: ownCooldown)?.event
                == .ownCast(guid: "Player-3676-0EE16FAF", name: "Medruid-Area52-US", spellID: 33891, spellName: "Incarnation: Tree of Life"))
    }

    // MARK: Tracker

    private func feed(_ lines: [String], cooldowns: Set<Int> = []) -> Library {
        var tracker = ActivityTracker()
        tracker.options.cooldownSpellIDs = cooldowns
        var library = Library()
        var offset: UInt64 = 0
        for line in lines {
            if let entry = CombatLogParser.parse(line: line, position: LogPosition(fileName: "log.txt", offset: offset)) {
                library.upsert(tracker.handle(entry))
            }
            offset += UInt64(line.utf8.count + 2)
        }
        return library
    }

    @Test func marksInterruptsDispelsLustCooldownsAndBattleRes() throws {
        let library = feed([keyStart, ownCooldown, ownInterrupt, groupInterrupt, petInterrupt, ownDispel, lust, battleRes, normalRes],
                           cooldowns: [33891])
        let key = try #require(library.activities.first)
        #expect(key.markers.map(\.kind) == [.cooldown, .interrupt, .interrupt, .dispel, .bloodlust, .battleRes])
        #expect(key.markers.map(\.label) == [
            "Incarnation: Tree of Life",
            "Interrupted Healing Touch",
            "Interrupted Spirit Bolt",
            "Dispelled Energy Bomb from Friend",
            "Bloodlust (Shamfriend)",
            "Rebirth on you (Lockfriend)",
        ])
    }

    @Test func yourOwnNameReadsAsYou() throws {
        let selfDispel = #"5/20/2026 14:22:40.000-7  SPELL_DISPEL,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,88423,"Nature's Cure",0x8,374350,"Energy Bomb",64,DEBUFF"#
        let ownLust = #"5/20/2026 14:22:57.167-7  SPELL_CAST_SUCCESS,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,0000000000000000,nil,0x80000000,0x80000000,2825,"Bloodlust",0x8,Player-3676-0EE16FAF,0000000000000000,498000,498000,864,2632,2225,718,51,0,11,118,150,0,5052.11,-3172.31,2497,0.5110,286"#
        let library = feed([keyStart, ownCooldown, selfDispel, ownLust])
        #expect(library.activities.first?.markers.map(\.label) == ["Dispelled Energy Bomb from you", "Bloodlust (you)"])
    }

    @Test func cooldownsNeedTheAddonsList() throws {
        let library = feed([keyStart, ownCooldown])
        #expect(library.activities.first?.markers.isEmpty == true)
    }

    @Test func markersOutsideActivitiesAreDropped() {
        #expect(feed([ownInterrupt, lust]).activities.isEmpty)
    }

    @Test func anyResurrectionDuringABossCounts() throws {
        let library = feed([
            #"5/20/2026 14:31:40.000-7  ENCOUNTER_START,3361,"Infiltrator Gulkat",16,20,3003"#,
            normalRes,
        ])
        #expect(library.activities.first?.markers.last?.kind == .battleRes)
    }

    @Test func deathMarkersRememberTheirLogLine() throws {
        let death = #"5/20/2026 14:30:41.151-7  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,0"#
        let library = feed([keyStart, death])
        let marker = try #require(library.activities.first?.markers.first)
        #expect(marker.kind == .playerDeath)
        #expect(marker.log == LogPosition(fileName: "log.txt", offset: UInt64(keyStart.utf8.count + 2)))
    }

    @Test func markerKindsHaveCategories() {
        #expect(Marker.Kind.bossWipe.category == .bosses)
        #expect(Marker.Kind.playerDeath.category == .deaths)
        #expect(Marker.Kind.death.category == .deaths)
        #expect(Marker.Kind.battleRes.category == .battleRes)
    }

    // MARK: Notes and clips

    @Test func notesSurviveTrackerUpdates() {
        var activity = Activity(kind: .mythicPlus, title: "Key", start: Date(timeIntervalSince1970: 0))
        var library = Library(activities: [activity])
        library.activities[0].notes = "Pulled too much at the second boss"
        activity.result = .completed
        library.upsert([activity])
        #expect(library.activities[0].notes == "Pulled too much at the second boss")
        #expect(library.activities[0].result == .completed)
    }

    @Test func clipKeepsMarkersInRangeButNotPullDetails() {
        let start = Date(timeIntervalSince1970: 1000)
        var pull = Activity(kind: .raidEncounter, title: "Boss", subtitle: "Raid · Mythic", start: start,
                            end: start.addingTimeInterval(300), result: .wipe, markers: [
                                Marker(date: start, kind: .bossPull, label: "Pull"),
                                Marker(date: start.addingTimeInterval(100), kind: .playerDeath, label: "You died"),
                                Marker(date: start.addingTimeInterval(300), kind: .bossWipe, label: "Wipe"),
                            ])
        pull.encounterID = 3361
        pull.character = "Me"
        pull.notes = "not copied"
        let clip = pull.clip(from: start.addingTimeInterval(90), to: start.addingTimeInterval(120))
        #expect(clip.kind == .clip)
        #expect(clip.title == "Boss (clip)")
        #expect(clip.markers.map(\.label) == ["You died"])
        #expect(clip.encounterID == nil)
        #expect(clip.character == "Me")
        #expect(clip.notes == nil)
        #expect(clip.id != pull.id)
    }

    @Test func readsCooldownsFromSavedVariables() {
        let text = """
        SessionRecorderHelperDB = {
            ["gameData"] = {
                ["cooldowns"] = {
                    [33891] = 180,
                    [102342] = 90,
                },
            },
        }
        """
        let db = LuaSavedVariables.parse(text)["SessionRecorderHelperDB"]!
        #expect(GameData(savedVariables: db).cooldowns == [33891: 180, 102342: 90])
    }

    // MARK: Death recap

    /// The last seconds of a real death, plus lines that must be left out.
    private let deathLines = [
        // A heal *from* the dead player to someone else: not part of their recap.
        #"5/20/2026 14:30:38.022-7  SPELL_PERIODIC_HEAL,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,Player-3676-0EA2F4F1,"Mebear-Area52-US",0x512,0x80000000,8936,"Regrowth",0x8,Player-3676-0EA2F4F1,0000000000000000,764119,764119,3740,619,4710,2188,0,19164,1,507,1000,0,5062.99,-3168.64,2497,1.9298,257,13109,13109,13109,0,1"#,
        // Too early: more than 10 seconds before the death.
        #"5/20/2026 14:30:30.000-7  SPELL_DAMAGE,Creature-0-3882-2805-123986-231629-00000E2530,"Latch",0xa48,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,472758,"Splattering Spew",0x8,Player-3676-0EE16FAF,0000000000000000,300000,384680,2294,2206,782,1066,320,0,3,100,100,0,5071.87,-3142.69,2497,1.6705,269,84680,84680,-1,8,0,0,0,nil,nil,nil,AOE"#,
        // A full overheal adds nothing.
        #"5/20/2026 14:30:39.140-7  SPELL_PERIODIC_HEAL,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,155777,"Rejuvenation (Germination)",0x8,Player-3676-0EE16FAF,0000000000000000,384680,384680,2294,2206,782,1066,320,0,0,181473,260000,0,5072.60,-3160.32,2497,1.6807,269,6978,6978,6978,0,nil"#,
        // Melee is logged twice; only the _LANDED twin carries the target's health.
        #"5/20/2026 14:30:40.017-7  SWING_DAMAGE,Creature-0-3882-2805-128712-238099-000F0E2CEF,"Pesty Lashling",0xa48,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,Creature-0-3882-2805-128712-238099-000F0E2CEF,0000000000000000,670722,670722,0,0,1470,0,0,0,1,0,0,0,5331.22,-3108.49,2494,4.3396,90,38272,51400,-1,1,0,0,0,nil,nil,nil"#,
        #"5/20/2026 14:30:40.050-7  SWING_DAMAGE_LANDED,Creature-0-3882-2805-128712-238099-000F0E2CEF,"Pesty Lashling",0xa48,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,Player-3676-0EE16FAF,0000000000000000,346408,384680,2374,2283,782,1066,320,0,0,207098,260000,0,5332.77,-3112.83,2494,5.6999,269,38272,51400,-1,1,0,0,0,nil,nil,nil"#,
        #"5/20/2026 14:30:40.925-7  SPELL_HEAL,Creature-0-3882-2805-123986-54983-00000E27FA,"Treant",0x2111,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,422090,"Nourish",0x8,Player-3676-0EE16FAF,0000000000000000,384680,384680,2294,2206,782,1066,320,0,3,100,100,0,5072.03,-3144.26,2497,1.6705,269,11321,11321,0,0,1"#,
        #"5/20/2026 14:30:41.068-7  SPELL_DAMAGE,Creature-0-3882-2805-123986-231629-00000E2530,"Latch",0xa48,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,472758,"Splattering Spew",0x8,Player-3676-0EE16FAF,0000000000000000,159729,384680,2294,2206,782,1066,320,0,3,100,100,0,5071.87,-3142.69,2497,1.6705,269,224951,129105,-1,8,0,0,0,nil,nil,nil,AOE"#,
        #"5/20/2026 14:30:41.146-7  SPELL_DAMAGE,Creature-0-3882-2805-123986-231629-00000E2530,"Latch",0xa48,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,472758,"Splattering Spew",0x8,Player-3676-0EE16FAF,0000000000000000,0,384680,2294,2206,782,466,320,0,0,185925,260000,0,5071.79,-3141.92,2497,1.6705,269,224951,129105,65222,8,0,0,0,nil,nil,nil,AOE"#,
        #"5/20/2026 14:30:41.151-7  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,0"#,
        #"5/20/2026 13:56:43.111-7  ENVIRONMENTAL_DAMAGE,0000000000000000,nil,0x80000000,0x80000000,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,Player-3676-0EE16FAF,0000000000000000,432177,493440,3036,637,1225,383,51,29606,0,214733,250000,0,5227.64,-3166.38,2493,4.8840,285,Falling,45008,45008,0,1,0,0,0,nil,nil,nil"#,
    ]

    private var deathDate: Date { CombatTimestamp.parse("5/20/2026 14:30:41.151-7")! }

    @Test func recapListsWhatHappenedBeforeADeath() throws {
        let recap = DeathRecap.build(lines: deathLines, unitGUID: "Player-3676-0EE16FAF", death: deathDate)
        #expect(recap.events.map(\.ability) == ["Melee", "Nourish", "Splattering Spew", "Splattering Spew"])
        #expect(recap.events.map(\.kind) == [.damage, .heal, .damage, .damage])
        #expect(recap.events.map(\.amount) == [38272, 11321, 224951, 224951])
        #expect(recap.events.map(\.source) == ["Pesty Lashling", "Treant", "Latch", "Latch"])
        #expect(recap.events[0].health == 346408)
        #expect(recap.events[2].healthPercent.map { Int($0.rounded()) } == 42)
        let blow = try #require(recap.killingBlow)
        #expect(blow.overkill == 65222)
        #expect(blow.health == 0)
        #expect(recap.damageTaken == 38272 + 224951 * 2)
        #expect(recap.healingReceived == 11321)
    }

    @Test func recapKeepsUnpairedMeleeAndEnvironmentDamage() throws {
        let fall = CombatTimestamp.parse("5/20/2026 13:56:43.111-7")!
        let recap = DeathRecap.build(lines: deathLines, unitGUID: "Player-3676-0EE16FAF", death: fall.addingTimeInterval(1))
        let event = try #require(recap.events.only)
        #expect(event.source == "Environment")
        #expect(event.ability == "Falling")
        #expect(event.amount == 45008)

        // Without its _LANDED twin, a swing still counts.
        let swingOnly = deathLines.filter { !$0.contains("SWING_DAMAGE_LANDED") }
        let melee = DeathRecap.build(lines: swingOnly, unitGUID: "Player-3676-0EE16FAF", death: deathDate)
        #expect(melee.events.first?.ability == "Melee")
        #expect(melee.events.first?.health == nil)
    }

    // MARK: Log files

    @Test func logFileNamesGiveTheirStartTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = try #require(CombatLogFiles.startDate(fileName: "WoWCombatLog-100626_225830.txt", calendar: calendar))
        #expect(calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                == DateComponents(year: 2026, month: 10, day: 6, hour: 22, minute: 58, second: 30))
        #expect(CombatLogFiles.startDate(fileName: "WoWCombatLog.txt") == nil)
        #expect(CombatLogFiles.startDate(fileName: "WoWCombatLog-archive-2026.txt") == nil)
    }

    @Test func findsTheLogThatCoversADate() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["WoWCombatLog-100626_200448.txt", "WoWCombatLog-100626_225830.txt", "notes.txt"] {
            try Data().write(to: directory.appending(path: name))
        }
        let late = try #require(CombatLogFiles.startDate(fileName: "WoWCombatLog-100626_230000.txt"))
        let early = try #require(CombatLogFiles.startDate(fileName: "WoWCombatLog-100626_210000.txt"))
        #expect(CombatLogFiles.file(at: late, in: directory)?.lastPathComponent == "WoWCombatLog-100626_225830.txt")
        #expect(CombatLogFiles.file(at: early, in: directory)?.lastPathComponent == "WoWCombatLog-100626_200448.txt")
        #expect(CombatLogFiles.file(at: Date.distantPast, in: directory) == nil)
    }

    /// A big synthetic log: one line every 10 ms for an hour, so finding the window needs both
    /// the timestamp search and the widening backwards read.
    @Test func readsTheWindowBeforeADeathFromALargeLog() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        let base = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 14))!
        let filler = String(repeating: "x", count: 150)
        var text = ""
        var offsets: [Int: Int] = [:]
        var bytes = 0
        for i in 0..<360_000 {
            let date = base.addingTimeInterval(Double(i) / 100)
            let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
            let ms = Int((Double(parts.nanosecond!) / 1e6).rounded())
            let stamp = String(format: "5/20/2026 %d:%02d:%02d.%03d-7", parts.hour!, parts.minute!, parts.second!, ms)
            let line = "\(stamp)  SPELL_CAST_SUCCESS,\(i),\(filler)\r\n"
            offsets[i] = bytes
            bytes += line.utf8.count
            text += line
        }
        try Data(text.utf8).write(to: url)

        // Death at 14:30:00, line 180000.
        let death = base.addingTimeInterval(1800)
        for anchor in [UInt64(offsets[180_000]!), nil] {
            let lines = try CombatLogFiles.lines(in: url, anchor: anchor, from: death.addingTimeInterval(-10), to: death)
            let indices = lines.compactMap { Int($0.split(separator: ",")[1]) }
            #expect(indices.first! <= 179_000, "reaches 10 s back (anchor \(String(describing: anchor)))")
            #expect(indices.last! >= 180_000, "reaches the death")
            #expect(zip(indices, indices.dropFirst()).allSatisfy { $1 == $0 + 1 }, "whole lines, in order, no gaps")
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
