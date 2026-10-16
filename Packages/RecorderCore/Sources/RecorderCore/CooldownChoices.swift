import Foundation

/// Which of your cooldowns show on the timeline and in the marker list.
///
/// Every cooldown the helper addon learns is marked when you cast it; this only decides what's
/// shown, so a change applies to earlier recordings too. Cooldowns of 2 minutes or more are
/// shown and shorter ones (Nature's Swiftness, utility totems) aren't, unless the player flips
/// them in Settings. Only the flips are kept, so newly learned spells follow the rule.
public struct CooldownChoices: Sendable, Equatable {
    /// Cooldowns at least this long, in seconds, are shown unless turned off.
    public static let shownFrom = 120

    /// Shorter cooldowns the player turned on.
    public var turnedOn: Set<Int>
    /// Longer cooldowns the player turned off.
    public var turnedOff: Set<Int>

    public init(turnedOn: Set<Int> = [], turnedOff: Set<Int> = []) {
        self.turnedOn = turnedOn
        self.turnedOff = turnedOff
    }

    /// A cooldown of unknown length is shown, as every cooldown was before there was a choice.
    public static func isShownByDefault(seconds: Int?) -> Bool {
        seconds.map { $0 >= shownFrom } ?? true
    }

    public func isShown(_ spellID: Int, seconds: Int?) -> Bool {
        if turnedOn.contains(spellID) { return true }
        if turnedOff.contains(spellID) { return false }
        return Self.isShownByDefault(seconds: seconds)
    }

    public mutating func setShown(_ shown: Bool, spellID: Int, seconds: Int?) {
        turnedOn.remove(spellID)
        turnedOff.remove(spellID)
        guard shown != Self.isShownByDefault(seconds: seconds) else { return }
        if shown { turnedOn.insert(spellID) } else { turnedOff.insert(spellID) }
    }

    /// Only cooldown markers are ever hidden here. Ones recorded before markers kept the spell ID
    /// are matched by name, and shown if that doesn't find the spell.
    public func shows(_ marker: Marker, cooldowns: LearnedCooldowns) -> Bool {
        guard marker.kind == .cooldown else { return true }
        let ids = marker.spellID.map { [$0] } ?? cooldowns.spellIDs(named: marker.label)
        guard !ids.isEmpty else { return true }
        return ids.contains { isShown($0, seconds: cooldowns[$0]?.seconds) }
    }
}

/// The cooldowns the helper addon learned, with their names and the class or spec they're from.
public struct LearnedCooldowns: Sendable, Equatable {
    public struct Spell: Sendable, Equatable, Identifiable {
        /// The spell ID.
        public var id: Int
        public var name: String
        /// Seconds.
        public var seconds: Int
        public var className: String?
        /// The spellbook tab it's on: the class or a spec.
        public var skillLine: String?

        public init(id: Int, name: String, seconds: Int, className: String? = nil, skillLine: String? = nil) {
            self.id = id
            self.name = name
            self.seconds = seconds
            self.className = className
            self.skillLine = skillLine
        }

        /// "1 min", "1.5 min", the way WoW's tooltips put it.
        public var durationText: String {
            guard seconds >= 60 else { return "\(seconds) sec" }
            return "\((Double(seconds) / 60).formatted(.number.precision(.fractionLength(0...1)))) min"
        }

        /// "Restoration Shaman", or "Shaman" for class spells. `nil` until helper 1.3.0 has run.
        public var group: String? {
            switch (skillLine, className) {
            case let (line?, className?) where line != className: "\(line) \(className)"
            case let (line, className): className ?? line
            }
        }

        /// The class's own spells, before its specs'.
        fileprivate var isClassSpell: Bool { skillLine == nil || skillLine == className }
    }

    public struct Group: Sendable, Equatable, Identifiable {
        /// `nil` for spells the addon hasn't placed yet.
        public var title: String?
        public var spells: [Spell]

        public var id: String { title ?? "" }
    }

    public private(set) var spells: [Int: Spell] = [:]
    /// Every name a cooldown has had, for markers that only have the name.
    private var idsByName: [String: Set<Int>] = [:]

    public init() {}

    /// Names come from the addon, else from cooldown markers (which have the name of the cast),
    /// else "Spell 12345".
    public init(gameData: GameData, markers: some Sequence<Marker>) {
        var markerNames: [Int: String] = [:]
        for marker in markers where marker.kind == .cooldown {
            guard let id = marker.spellID else { continue }
            markerNames[id] = marker.label
            // Every name, not just the last: a spell can be renamed or logged in another language.
            idsByName[marker.label, default: []].insert(id)
        }
        for (id, info) in gameData.cooldownSpells {
            if let name = info.name { idsByName[name, default: []].insert(id) }
        }
        // Battle resses and Bloodlust get markers of their own, so a choice wouldn't do anything.
        for (id, seconds) in gameData.cooldowns
        where !CombatLogParser.battleResSpellIDs.contains(id) && !CombatLogParser.bloodlustSpellIDs.contains(id) {
            let info = gameData.cooldownSpells[id]
            spells[id] = Spell(id: id, name: info?.name ?? markerNames[id] ?? "Spell \(id)", seconds: seconds,
                               className: info?.className, skillLine: info?.skillLine)
        }
    }

    public subscript(spellID: Int) -> Spell? { spells[spellID] }

    public func spellIDs(named name: String) -> [Int] {
        idsByName[name].map { $0.sorted() } ?? []
    }

    /// By class, the class's own spells before each spec's; spells the addon hasn't placed go
    /// last. Longest cooldown first within each group.
    public var groups: [Group] {
        Dictionary(grouping: spells.values, by: \.group)
            .map { title, spells in
                Group(title: title, spells: spells.sorted {
                    ($0.seconds, $1.name) > ($1.seconds, $0.name)
                })
            }
            .sorted { a, b in
                let (x, y) = (a.spells[0], b.spells[0])
                if (a.title == nil) != (b.title == nil) { return b.title == nil }
                if x.className != y.className { return (x.className ?? x.skillLine ?? "") < (y.className ?? y.skillLine ?? "") }
                if x.isClassSpell != y.isClassSpell { return x.isClassSpell }
                return (a.title ?? "") < (b.title ?? "")
            }
    }
}
