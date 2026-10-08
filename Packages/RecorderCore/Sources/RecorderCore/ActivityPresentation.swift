import Foundation

/// How an activity reads in the library: its result badge, caption and tooltip.
public enum ActivityPresentation {
    public enum Tone: Sendable, Equatable {
        case positive, negative, warning, neutral, active
    }

    public struct Badge: Sendable, Equatable {
        public var text: String
        public var tone: Tone
    }

    public static func badge(for activity: Activity, gameData: GameData) -> Badge {
        if activity.kind == .mythicPlus, activity.result == .completed, let outcome = keystoneOutcome(activity, gameData) {
            switch outcome {
            case .timed: return Badge(text: outcome.displayName, tone: .positive)
            case .depleted: return Badge(text: outcome.displayName, tone: .warning)
            }
        }
        if activity.result == .wipe, let health = activity.bossHealthPercent {
            return Badge(text: "Wipe · \(Int(health.rounded()))%", tone: .negative)
        }
        let tone: Tone = switch activity.result {
        case .kill, .completed, .win: .positive
        case .wipe, .loss: .negative
        case .abandoned: .warning
        case .inProgress: .active
        case .unknown: .neutral
        }
        return Badge(text: activity.result.displayName, tone: tone)
    }

    public static func keystoneOutcome(_ activity: Activity, _ gameData: GameData) -> KeystoneOutcome? {
        guard let time = activity.keyTimeMs, let map = activity.challengeModeID,
              let limit = gameData.keystones[map]?.timeLimit else { return nil }
        return KeystoneOutcome(keyTimeMs: time, timeLimit: limit)
    }

    /// The second line: where/what, pull number, and the player's spec.
    public static func caption(for activity: Activity, gameData: GameData, pullNumber: Int?) -> String {
        var parts: [String] = [activity.subtitle.isEmpty ? activity.kind.displayName : activity.subtitle]
        if let pullNumber { parts.append("Pull \(pullNumber)") }
        if let spec = activity.specID.flatMap(gameData.spec) { parts.append(spec.displayName) }
        return parts.joined(separator: " · ")
    }

    /// Extra detail shown on hover: character, group, affixes and notes.
    public static func tooltip(for activity: Activity, gameData: GameData) -> String {
        var lines: [String] = []
        if let character = activity.character { lines.append("Character: \(character)") }
        if let group = activity.groupSpecIDs, group.count > 1 {
            lines.append("Group: " + group.compactMap { gameData.spec($0)?.displayName }.joined(separator: ", "))
        }
        if let affixes = activity.affixIDs, !affixes.isEmpty {
            lines.append("Affixes: " + affixes.map { gameData.affixes[$0] ?? "#\($0)" }.joined(separator: ", "))
        }
        if let time = activity.keyTimeMs, let map = activity.challengeModeID, let limit = gameData.keystones[map]?.timeLimit {
            lines.append("Time: \(ActivityTracker.formatDuration(Double(time) / 1000)) of \(ActivityTracker.formatDuration(Double(limit)))")
        }
        if let notes = activity.notes {
            lines.append("Notes: \(notes)")
        }
        return lines.joined(separator: "\n")
    }

    /// Numbers each boss pull per encounter and difficulty within a day, oldest first, so the
    /// tenth attempt on a boss tonight reads "Pull 10".
    public static func pullNumbers(_ activities: [Activity], calendar: Calendar = .current) -> [UUID: Int] {
        struct Key: Hashable { var encounter: Int; var difficulty: Int; var day: Date }
        var counts: [Key: Int] = [:]
        var numbers: [UUID: Int] = [:]
        for activity in activities.sorted(by: { $0.start < $1.start }) {
            guard let encounter = activity.encounterID else { continue }
            let key = Key(encounter: encounter, difficulty: activity.difficultyID ?? 0, day: calendar.startOfDay(for: activity.start))
            counts[key, default: 0] += 1
            numbers[activity.id] = counts[key]
        }
        return numbers
    }
}
