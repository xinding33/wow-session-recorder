import Foundation
import Testing
@testable import RecorderCore

/// Which cooldown markers show, and the Settings list they're chosen from.
struct CooldownTests {
    // Nature's Swiftness (1 min), Spirit Link Totem (3 min), Healing Tide Totem (3 min),
    // Capacitor Totem (1 min) and Rebirth.
    private let gameData = GameData(
        cooldowns: [378081: 60, 98008: 180, 108280: 180, 192058: 60, 20484: 600],
        cooldownSpells: [
            378081: .init(name: "Nature's Swiftness", className: "Shaman", skillLine: "Shaman"),
            98008: .init(name: "Spirit Link Totem", className: "Shaman", skillLine: "Restoration"),
            108280: .init(name: "Healing Tide Totem", className: "Shaman", skillLine: "Restoration"),
            20484: .init(name: "Rebirth", className: "Druid", skillLine: "Druid"),
        ])

    private func cooldown(_ label: String, spellID: Int? = nil) -> Marker {
        Marker(date: Date(timeIntervalSince1970: 0), kind: .cooldown, label: label, spellID: spellID)
    }

    @Test func twoMinutesOrMoreAreShownByDefault() {
        let choices = CooldownChoices()
        #expect(choices.isShown(98008, seconds: 180))
        #expect(choices.isShown(1, seconds: 120))
        #expect(!choices.isShown(378081, seconds: 60))
        #expect(!choices.isShown(1, seconds: 119))
        // Unknown length: shown, as before there was a choice.
        #expect(choices.isShown(1, seconds: nil))
    }

    @Test func onlyFlipsAreKept() {
        var choices = CooldownChoices()
        choices.setShown(true, spellID: 378081, seconds: 60)
        choices.setShown(false, spellID: 98008, seconds: 180)
        #expect(choices == CooldownChoices(turnedOn: [378081], turnedOff: [98008]))
        #expect(choices.isShown(378081, seconds: 60))
        #expect(!choices.isShown(98008, seconds: 180))

        // Flipping back to the default forgets the spell, so it follows the rule again.
        choices.setShown(false, spellID: 378081, seconds: 60)
        choices.setShown(true, spellID: 98008, seconds: 180)
        #expect(choices == CooldownChoices())
    }

    @Test func filtersCooldownMarkersBySpell() {
        let learned = LearnedCooldowns(gameData: gameData, markers: [])
        var choices = CooldownChoices()
        #expect(choices.shows(cooldown("Spirit Link Totem", spellID: 98008), cooldowns: learned))
        #expect(!choices.shows(cooldown("Nature's Swiftness", spellID: 378081), cooldowns: learned))
        // Other markers aren't this filter's business.
        #expect(choices.shows(Marker(date: Date(), kind: .interrupt, label: "Interrupted Bolt"), cooldowns: learned))

        choices.setShown(true, spellID: 378081, seconds: 60)
        #expect(choices.shows(cooldown("Nature's Swiftness", spellID: 378081), cooldowns: learned))
    }

    @Test func olderMarkersAreMatchedByName() {
        let learned = LearnedCooldowns(gameData: gameData, markers: [])
        var choices = CooldownChoices()
        #expect(choices.shows(cooldown("Spirit Link Totem"), cooldowns: learned))
        #expect(!choices.shows(cooldown("Nature's Swiftness"), cooldowns: learned))
        choices.setShown(false, spellID: 98008, seconds: 180)
        #expect(!choices.shows(cooldown("Spirit Link Totem"), cooldowns: learned))
        // Nothing to go on: shown.
        #expect(choices.shows(cooldown("Some Old Spell"), cooldowns: learned))

        // Before the addon saves names, newer markers say which spell a name is.
        let unnamed = LearnedCooldowns(gameData: GameData(cooldowns: gameData.cooldowns),
                                       markers: [cooldown("Nature's Swiftness", spellID: 378081)])
        #expect(!CooldownChoices().shows(cooldown("Nature's Swiftness"), cooldowns: unnamed))

        // Every name a spell was cast under counts, e.g. from a client in another language.
        let renamed = LearnedCooldowns(gameData: GameData(cooldowns: gameData.cooldowns),
                                       markers: [cooldown("Rapidez de la Naturaleza", spellID: 378081),
                                                 cooldown("Nature's Swiftness", spellID: 378081)])
        #expect(!CooldownChoices().shows(cooldown("Rapidez de la Naturaleza"), cooldowns: renamed))
        #expect(!CooldownChoices().shows(cooldown("Nature's Swiftness"), cooldowns: renamed))
    }

    @Test func namesFallBackToMarkersThenTheSpellID() throws {
        let learned = LearnedCooldowns(gameData: GameData(cooldowns: [378081: 60, 192058: 60]),
                                       markers: [cooldown("Nature's Swiftness", spellID: 378081)])
        #expect(learned[378081]?.name == "Nature's Swiftness")
        #expect(learned[192058]?.name == "Spell 192058")
        #expect(learned[192058]?.group == nil)
        let group = try #require(learned.groups.only)
        #expect(group.title == nil)
    }

    @Test func groupsByClassThenSpec() {
        var data = gameData
        data.cooldowns[33891] = 180
        data.cooldownSpells[33891] = .init(name: "Incarnation: Tree of Life", className: "Druid", skillLine: "Restoration")
        let learned = LearnedCooldowns(gameData: data, markers: [])
        // Capacitor Totem has no name or tab yet, so it goes last.
        #expect(learned.groups.map(\.title) == ["Restoration Druid", "Shaman", "Restoration Shaman", nil])
        // Longest first, then by name.
        #expect(learned.groups[2].spells.map(\.name) == ["Healing Tide Totem", "Spirit Link Totem"])
        // Battle resses get their own markers, so they aren't listed.
        #expect(learned[20484] == nil)
    }

    @Test func durationsReadLikeTooltips() {
        #expect(LearnedCooldowns.Spell(id: 1, name: "A", seconds: 60).durationText == "1 min")
        #expect(LearnedCooldowns.Spell(id: 1, name: "A", seconds: 180).durationText == "3 min")
        #expect(LearnedCooldowns.Spell(id: 1, name: "A", seconds: 45).durationText == "45 sec")
    }

    @Test func cooldownMarkersKeepTheirSpellID() throws {
        let cast = #"5/20/2026 14:23:10.000-7  SPELL_CAST_SUCCESS,Player-3676-0EE16FAF,"Medruid-Area52-US",0x511,0x80000000,0000000000000000,nil,0x80000000,0x80000000,33891,"Incarnation: Tree of Life",0x8,Player-3676-0EE16FAF,0000000000000000,384680,384680,2294,2206,782,1066,320,0,0,180645,260000,0,5071.26,-3165.49,2497,1.6807,269"#
        var tracker = ActivityTracker()
        tracker.options.cooldownSpellIDs = [33891]
        _ = tracker.handle(try #require(CombatLogParser.parse(line: #"5/20/2026 14:20:00.000-7  CHALLENGE_MODE_START,"Priory of the Sacred Flame",2649,499,10,[162,10,9]"#)))
        let changed = tracker.handle(try #require(CombatLogParser.parse(line: cast)))
        #expect(changed.last?.markers.last?.spellID == 33891)
    }

    @Test func markersSavedWithoutASpellIDStillLoad() throws {
        let json = #"{"id":"6F1C7C2E-6A43-4C8B-9E0B-1A2B3C4D5E6F","date":0,"kind":"cooldown","label":"Spirit Link Totem"}"#
        let marker = try JSONDecoder().decode(Marker.self, from: Data(json.utf8))
        #expect(marker.spellID == nil)
        #expect(marker.label == "Spirit Link Totem")
    }

    @Test func readsCooldownNamesFromSavedVariables() {
        let text = """
        SessionRecorderHelperDB = {
            ["gameData"] = {
                ["cooldowns"] = {
                    [98008] = 180,
                    [192058] = 60,
                },
                ["cooldownSpells"] = {
                    [98008] = {
                        ["name"] = "Spirit Link Totem",
                        ["class"] = "Shaman",
                        ["line"] = "Restoration",
                    },
                    [192058] = {
                        ["class"] = "Shaman",
                    },
                },
            },
        }
        """
        let data = GameData(savedVariables: LuaSavedVariables.parse(text)["SessionRecorderHelperDB"]!)
        #expect(data.cooldowns == [98008: 180, 192058: 60])
        #expect(data.cooldownSpells == [
            98008: .init(name: "Spirit Link Totem", className: "Shaman", skillLine: "Restoration"),
            192058: .init(className: "Shaman"),
        ])
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
