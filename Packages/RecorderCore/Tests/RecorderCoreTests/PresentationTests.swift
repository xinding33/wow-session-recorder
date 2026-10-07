import Foundation
import Testing
@testable import RecorderCore

struct PresentationTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let gameData = GameData(
        keystones: [402: .init(name: "Algeth'ar Academy", timeLimit: 1800)],
        affixes: [10: "Fortified", 9: "Tyrannical"])

    private func key(timeMs: Int) -> Activity {
        var key = Activity(kind: .mythicPlus, title: "Algeth'ar Academy +10", subtitle: "Mythic+ · 16:57",
                           start: t0, end: t0 + 1017, result: .completed)
        key.challengeModeID = 402
        key.keyTimeMs = timeMs
        key.affixIDs = [10, 9]
        key.specID = 264
        key.groupSpecIDs = [104, 264, 270]
        key.character = "Leafwhisper"
        return key
    }

    @Test func keyBadgeUsesTheTimerWhenKnown() {
        #expect(ActivityPresentation.badge(for: key(timeMs: 1_016_591), gameData: gameData) == .init(text: "Timed +3", tone: .positive))
        #expect(ActivityPresentation.badge(for: key(timeMs: 1_900_000), gameData: gameData) == .init(text: "Depleted", tone: .warning))
        // Without the addon's timers it can only say the key finished.
        #expect(ActivityPresentation.badge(for: key(timeMs: 1_016_591), gameData: GameData()) == .init(text: "Completed", tone: .positive))
    }

    @Test func wipeBadgeShowsBossHealth() {
        var pull = Activity(kind: .raidEncounter, title: "Boss", start: t0, end: t0 + 60, result: .wipe)
        pull.bossHealthPercent = 34.4
        #expect(ActivityPresentation.badge(for: pull, gameData: gameData) == .init(text: "Wipe · 34%", tone: .negative))
    }

    @Test func captionAndTooltip() {
        #expect(ActivityPresentation.caption(for: key(timeMs: 1_016_591), gameData: gameData, pullNumber: nil)
                == "Mythic+ · 16:57 · Restoration Shaman")
        let tooltip = ActivityPresentation.tooltip(for: key(timeMs: 1_016_591), gameData: gameData)
        #expect(tooltip == """
            Character: Leafwhisper
            Group: Guardian Druid, Restoration Shaman, Mistweaver Monk
            Affixes: Fortified, Tyrannical
            Time: 16:57 of 30:00
            """)
    }

    @Test func pullsAreNumberedPerBossPerDay() {
        func pull(_ offset: TimeInterval, boss: Int, difficulty: Int = 16) -> Activity {
            var a = Activity(kind: .raidEncounter, title: "Boss \(boss)", start: t0 + offset, end: t0 + offset + 60, result: .wipe)
            a.encounterID = boss
            a.difficultyID = difficulty
            return a
        }
        let pulls = [pull(0, boss: 1), pull(300, boss: 1), pull(600, boss: 2), pull(900, boss: 1),
                     pull(1200, boss: 1, difficulty: 15), pull(86_400 * 2, boss: 1)]
        let numbers = ActivityPresentation.pullNumbers(pulls.shuffled())
        #expect(pulls.map { numbers[$0.id] } == [1, 2, 1, 3, 1, 1])
    }
}
