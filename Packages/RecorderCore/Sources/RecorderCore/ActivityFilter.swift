import Foundation

/// What the library is showing: the sidebar's choice plus search text and filters.
public struct ActivityFilter: Sendable, Equatable {
    /// A dungeon, raid or delve, or one boss in it.
    public enum Place: Sendable, Hashable {
        case instance(String)
        case boss(encounterID: Int)
    }

    public enum Outcome: String, Sendable, CaseIterable, Identifiable {
        case kill
        case wipe
        case timed
        case depleted
        /// Any finished key or delve, timed or not.
        case completed
        case abandoned

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .kill: "Kill"
            case .wipe: "Wipe"
            case .timed: "Timed"
            case .depleted: "Depleted"
            case .completed: "Completed"
            case .abandoned: "Abandoned"
            }
        }
    }

    public enum DatePreset: String, Sendable, CaseIterable, Identifiable {
        case today
        case last7Days
        case last30Days

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .today: "Today"
            case .last7Days: "Last 7 days"
            case .last30Days: "Last 30 days"
            }
        }

        /// The first and last day the preset covers.
        public func days(now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date) {
            let today = calendar.startOfDay(for: now)
            let back = switch self {
            case .today: 0
            case .last7Days: 6
            case .last30Days: 29
            }
            return (calendar.date(byAdding: .day, value: -back, to: today) ?? today, today)
        }
    }

    // Set by the sidebar.
    public var kind: ActivityKind?
    public var favoritesOnly = false

    /// Words to find in the title, subtitle or notes. Every word has to match somewhere.
    public var text = ""
    public var place: Place?
    /// Any of these. Empty means any result.
    public var outcomes: Set<Outcome> = []
    /// Lowest and highest key level, inclusive. Setting either hides everything that isn't a key.
    public var minKeyLevel: Int?
    public var maxKeyLevel: Int?
    /// First and last day, inclusive, by when the activity started.
    public var fromDay: Date?
    public var toDay: Date?
    public var character: String?

    public init() {}

    /// How many of the filters (not the sidebar or search text) are set.
    public var activeFilterCount: Int {
        [place != nil, !outcomes.isEmpty, minKeyLevel != nil || maxKeyLevel != nil,
         fromDay != nil || toDay != nil, character != nil].filter { $0 }.count
    }

    /// Search text and filters, but not the sidebar choice.
    public var isNarrowed: Bool { activeFilterCount > 0 || !searchWords.isEmpty }

    public mutating func clear() {
        text = ""
        place = nil
        outcomes = []
        minKeyLevel = nil
        maxKeyLevel = nil
        fromDay = nil
        toDay = nil
        character = nil
    }

    public func apply(_ activities: [Activity], gameData: GameData, calendar: Calendar = .current) -> [Activity] {
        let words = searchWords
        let days = dayBounds(calendar: calendar)
        return activities.filter { matches($0, words: words, days: days, gameData: gameData) }
    }

    public func matches(_ activity: Activity, gameData: GameData, calendar: Calendar = .current) -> Bool {
        matches(activity, words: searchWords, days: dayBounds(calendar: calendar), gameData: gameData)
    }

    private var searchWords: [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func dayBounds(calendar: Calendar) -> (from: Date?, until: Date?) {
        let from = fromDay.map { calendar.startOfDay(for: $0) }
        let until = toDay.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        return (from, until)
    }

    private func matches(_ activity: Activity, words: [String], days: (from: Date?, until: Date?),
                         gameData: GameData) -> Bool {
        if let kind, activity.kind != kind { return false }
        if favoritesOnly, !activity.isFavorite { return false }
        if let character, activity.character != character { return false }
        if let from = days.from, activity.start < from { return false }
        if let until = days.until, activity.start >= until { return false }
        if minKeyLevel != nil || maxKeyLevel != nil {
            guard let level = activity.keystoneLevel else { return false }
            if let minKeyLevel, level < minKeyLevel { return false }
            if let maxKeyLevel, level > maxKeyLevel { return false }
        }
        switch place {
        case .instance(let name)?:
            if LibraryFacets.instanceName(of: activity) != name { return false }
        case .boss(let id)?:
            if activity.encounterID != id { return false }
        case nil:
            break
        }
        if !outcomes.isEmpty, !outcomes.contains(where: { matches(activity, outcome: $0, gameData: gameData) }) {
            return false
        }
        if !words.isEmpty {
            let fields = [activity.title, activity.subtitle, activity.notes ?? ""]
            for word in words where !fields.contains(where: { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                return false
            }
        }
        return true
    }

    private func matches(_ activity: Activity, outcome: Outcome, gameData: GameData) -> Bool {
        switch outcome {
        case .kill: activity.result == .kill
        case .wipe: activity.result == .wipe
        case .completed: activity.result == .completed
        case .abandoned: activity.result == .abandoned
        case .timed, .depleted:
            switch (outcome, ActivityPresentation.keystoneOutcome(activity, gameData)) {
            case (.timed, .timed?), (.depleted, .depleted?): activity.result == .completed
            default: false
            }
        }
    }
}

/// The choices the library's filters offer, taken from what's in the library.
public struct LibraryFacets: Sendable, Equatable {
    public enum Group: Int, Sendable, CaseIterable, Comparable {
        case dungeons, raids, delves, other

        public var displayName: String {
            switch self {
            case .dungeons: "Dungeons"
            case .raids: "Raids"
            case .delves: "Delves"
            case .other: "Other"
            }
        }

        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Boss: Sendable, Hashable, Identifiable {
        public var id: Int
        public var name: String
    }

    public struct Instance: Sendable, Hashable, Identifiable {
        public var name: String
        public var group: Group
        /// Bosses pulled outside a key or delve run, by name.
        public var bosses: [Boss]
        public var id: String { name }
    }

    /// Sorted by group, then name.
    public var instances: [Instance] = []
    /// Bosses whose instance isn't known.
    public var otherBosses: [Boss] = []
    public var characters: [String] = []
    public var keyLevels: ClosedRange<Int>?

    public init(_ activities: [Activity]) {
        var groups: [String: Group] = [:]
        var bosses: [String?: [Int: String]] = [:]
        var characters: Set<String> = []
        var levels: [Int] = []
        // Newest first, so a boss keeps its latest name.
        for activity in activities.sorted(by: { $0.start > $1.start }) {
            let instance = Self.instanceName(of: activity)
            if let instance {
                let group = Self.group(of: activity.kind)
                groups[instance] = min(groups[instance] ?? group, group)
            }
            if let id = activity.encounterID, bosses[instance]?[id] == nil {
                bosses[instance, default: [:]][id] = activity.title
            }
            if let character = activity.character { characters.insert(character) }
            if let level = activity.keystoneLevel { levels.append(level) }
        }
        func sorted(_ list: [Int: String]?) -> [Boss] {
            (list ?? [:]).map { Boss(id: $0.key, name: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        instances = groups
            .map { Instance(name: $0.key, group: $0.value, bosses: sorted(bosses[$0.key])) }
            .sorted { ($0.group, $0.name.lowercased()) < ($1.group, $1.name.lowercased()) }
        otherBosses = sorted(bosses[nil])
        self.characters = characters.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if let low = levels.min(), let high = levels.max() { keyLevels = low...high }
    }

    /// A short label for a place, e.g. on a filter button.
    public func name(of place: ActivityFilter.Place) -> String {
        switch place {
        case .instance(let name): name
        case .boss(let id):
            (instances.flatMap(\.bosses) + otherBosses).first { $0.id == id }?.name ?? "Boss #\(id)"
        }
    }

    private static func group(of kind: ActivityKind) -> Group {
        switch kind {
        case .mythicPlus, .dungeonEncounter: .dungeons
        case .raidEncounter: .raids
        case .delve: .delves
        case .encounter, .arena, .clip: .other
        }
    }

    /// Where an activity happened. Activities recorded before this was saved are worked out
    /// from their titles.
    public static func instanceName(of activity: Activity) -> String? {
        if let name = activity.instanceName { return name.isEmpty ? nil : name }
        let parts = activity.subtitle.components(separatedBy: " · ")
        switch activity.kind {
        case .mythicPlus:
            // "Algeth'ar Academy +10"
            guard let plus = activity.title.range(of: " +", options: .backwards) else { return activity.title }
            return String(activity.title[..<plus.lowerBound])
        case .delve:
            // Early delve runs were titled after their boss, with the delve in the subtitle.
            return parts.count > 1 && parts[0] != "Delve" ? parts[0] : activity.title
        case .raidEncounter, .dungeonEncounter, .encounter:
            // "Zone · Difficulty", or just the difficulty when the zone wasn't known.
            if parts.count > 1 { return parts[0] }
            let isDifficulty = activity.difficultyID.flatMap(Difficulty.name(for:)) == parts[0]
            return parts[0].isEmpty || isDifficulty ? nil : parts[0]
        case .arena:
            return activity.subtitle.isEmpty ? nil : activity.subtitle
        case .clip:
            // Bookmarks and manual clips have the zone as their subtitle; trimmed clips don't.
            guard activity.title == "Bookmark" || activity.title == "Clip", !activity.subtitle.isEmpty else { return nil }
            return activity.subtitle
        }
    }
}
