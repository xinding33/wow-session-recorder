import Foundation

/// What kind of gameplay an activity represents.
public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case mythicPlus
    case raidEncounter
    case dungeonEncounter
    case delve
    case encounter
    case arena
    case clip

    public var displayName: String {
        switch self {
        case .mythicPlus: "Mythic+"
        case .raidEncounter: "Raid"
        case .dungeonEncounter: "Dungeon"
        case .delve: "Delve"
        case .encounter: "Encounter"
        case .arena: "Arena"
        case .clip: "Clip"
        }
    }
}

public enum ActivityResult: String, Codable, Sendable {
    case inProgress
    case kill
    case wipe
    case completed
    case abandoned
    case win
    case loss
    case unknown

    public var displayName: String {
        switch self {
        case .inProgress: "In progress"
        case .kill: "Kill"
        case .wipe: "Wipe"
        case .completed: "Completed"
        case .abandoned: "Abandoned"
        case .win: "Win"
        case .loss: "Loss"
        case .unknown: "Ended"
        }
    }
}

/// A point of interest inside an activity, shown on the playback timeline.
public struct Marker: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case bossPull
        case bossKill
        case bossWipe
        /// The recording player died.
        case playerDeath
        /// Another player in the group died.
        case death
        case bookmark
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var label: String

    public init(id: UUID = UUID(), date: Date, kind: Kind, label: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.label = label
    }
}

/// A labelled span of gameplay: a boss pull, a key, an arena match, or a manual clip.
public struct Activity: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: ActivityKind
    public var title: String
    public var subtitle: String
    public var start: Date
    /// `nil` while the activity is still in progress.
    public var end: Date?
    public var result: ActivityResult
    public var markers: [Marker]
    public var isFavorite: Bool

    public init(
        id: UUID = UUID(),
        kind: ActivityKind,
        title: String,
        subtitle: String = "",
        start: Date,
        end: Date? = nil,
        result: ActivityResult = .inProgress,
        markers: [Marker] = [],
        isFavorite: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.start = start
        self.end = end
        self.result = result
        self.markers = markers
        self.isFavorite = isFavorite
    }

    public var isInProgress: Bool { end == nil }

    public func duration(now: Date = Date()) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }
}

public enum Difficulty {
    /// Human-readable names for WoW difficulty IDs that show up in the combat log.
    public static func name(for id: Int) -> String? {
        switch id {
        case 1: "Normal"
        case 2: "Heroic"
        case 3: "10 Player"
        case 4: "25 Player"
        case 5: "10 Player (Heroic)"
        case 6: "25 Player (Heroic)"
        case 7, 17: "LFR"
        case 8: "Mythic Keystone"
        case 9: "40 Player"
        case 14: "Normal"
        case 15: "Heroic"
        case 16: "Mythic"
        case 23: "Mythic"
        case 24, 33: "Timewalking"
        case 205: "Follower"
        case 208: "Delve"
        case 220: "Story"
        default: nil
        }
    }

    static let raid: Set<Int> = [3, 4, 5, 6, 7, 9, 14, 15, 16, 17, 33, 151, 220]
    static let dungeon: Set<Int> = [1, 2, 8, 23, 24, 150, 205]
    static let delve: Set<Int> = [208]

    /// Dungeons, raids and delves. PvP instances aren't included.
    public static func isInstance(_ id: Int) -> Bool {
        raid.contains(id) || dungeon.contains(id) || delve.contains(id)
    }

    static func activityKind(for id: Int) -> ActivityKind {
        if raid.contains(id) { return .raidEncounter }
        if dungeon.contains(id) { return .dungeonEncounter }
        if delve.contains(id) { return .delve }
        return .encounter
    }
}
