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
        /// The player (or their pet) interrupted a cast.
        case interrupt
        /// The player dispelled or purged an aura.
        case dispel
        /// The player used one of their major cooldowns.
        case cooldown
        /// Bloodlust, Heroism, Time Warp or similar.
        case bloodlust
        case battleRes

        public var category: MarkerCategory {
            switch self {
            case .bossPull, .bossKill, .bossWipe: .bosses
            case .playerDeath, .death: .deaths
            case .bookmark: .bookmarks
            case .interrupt: .interrupts
            case .dispel: .dispels
            case .cooldown: .cooldowns
            case .bloodlust: .bloodlust
            case .battleRes: .battleRes
            }
        }
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var label: String
    /// The unit the marker is about, e.g. who died.
    public var unitGUID: String?
    /// Where the marker's line is in the combat log, so a death recap can read what led up to it.
    public var log: LogPosition?

    public init(id: UUID = UUID(), date: Date, kind: Kind, label: String, unitGUID: String? = nil, log: LogPosition? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.label = label
        self.unitGUID = unitGUID
        self.log = log
    }
}

/// Groups of marker kinds the player can show or hide together.
public enum MarkerCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case bosses
    case deaths
    case interrupts
    case dispels
    case cooldowns
    case bloodlust
    case battleRes
    case bookmarks

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bosses: "Boss pulls, kills and wipes"
        case .deaths: "Deaths"
        case .interrupts: "Your interrupts"
        case .dispels: "Your dispels"
        case .cooldowns: "Your cooldowns"
        case .bloodlust: "Bloodlust"
        case .battleRes: "Battle res"
        case .bookmarks: "Bookmarks"
        }
    }
}

/// Where an activity's lines live in the combat log, so details can be re-read later.
public struct LogRange: Codable, Sendable, Hashable {
    public var fileName: String
    public var startOffset: UInt64
    /// `nil` when the activity ended in a different log file (e.g. after a relog).
    public var endOffset: UInt64?

    public init(fileName: String, startOffset: UInt64, endOffset: UInt64? = nil) {
        self.fileName = fileName
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

/// A byte position in a combat log file.
public struct LogPosition: Codable, Sendable, Hashable {
    public var fileName: String
    public var offset: UInt64

    public init(fileName: String, offset: UInt64) {
        self.fileName = fileName
        self.offset = offset
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

    // Details read from the combat log. All optional so older libraries still decode.

    /// The recording player's character name, without realm.
    public var character: String?
    /// The recording player's specialization ID.
    public var specID: Int?
    /// Specialization IDs of everyone in the group, including the player.
    public var groupSpecIDs: [Int]?
    /// The dungeon, raid, delve or zone it happened in.
    public var instanceName: String?
    public var encounterID: Int?
    public var difficultyID: Int?
    /// Lowest health the boss reached, 0–100, for wipes.
    public var bossHealthPercent: Double?
    public var challengeModeID: Int?
    public var keystoneLevel: Int?
    public var affixIDs: [Int]?
    /// The key's official time, including death penalties.
    public var keyTimeMs: Int?
    public var log: LogRange?

    /// The player's own notes. Kept when the tracker updates the activity.
    public var notes: String?

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

    /// A clip of part of this activity, e.g. a trimmed fight, kept in the library on its own.
    /// Markers outside the range are dropped; boss and key details aren't carried over, so the
    /// clip doesn't count as a pull.
    public func clip(from start: Date, to end: Date, title: String? = nil) -> Activity {
        var clip = Activity(
            kind: .clip,
            title: title ?? "\(self.title) (clip)",
            subtitle: subtitle,
            start: start,
            end: end,
            result: .unknown,
            markers: markers.filter { $0.date >= start && $0.date <= end }
        )
        clip.instanceName = instanceName
        clip.character = character
        clip.specID = specID
        clip.groupSpecIDs = groupSpecIDs
        clip.log = log
        return clip
    }

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
