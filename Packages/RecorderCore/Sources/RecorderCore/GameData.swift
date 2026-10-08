import Foundation

/// Names and timers read from the game by the helper addon (saved in its SavedVariables).
///
/// The combat log only has IDs. The addon looks these up in game, so new seasons, dungeons and
/// specs work without app updates. Built-in spec names cover the gap until the addon has run.
public struct GameData: Sendable, Equatable {
    public struct Keystone: Sendable, Equatable {
        public var name: String
        /// Seconds.
        public var timeLimit: Int

        public init(name: String, timeLimit: Int) {
            self.name = name
            self.timeLimit = timeLimit
        }
    }

    public struct Spec: Sendable, Equatable {
        public var spec: String
        public var className: String

        public init(spec: String, className: String) {
            self.spec = spec
            self.className = className
        }

        public var displayName: String { "\(spec) \(className)" }
    }

    public var keystones: [Int: Keystone] = [:]
    public var affixes: [Int: String] = [:]
    public var specs: [Int: Spec] = [:]
    /// Your characters' major cooldowns: spell ID → base cooldown in seconds.
    public var cooldowns: [Int: Int] = [:]

    public init(keystones: [Int: Keystone] = [:], affixes: [Int: String] = [:], specs: [Int: Spec] = [:],
                cooldowns: [Int: Int] = [:]) {
        self.keystones = keystones
        self.affixes = affixes
        self.specs = specs
        self.cooldowns = cooldowns
    }

    public func spec(_ id: Int) -> Spec? {
        specs[id] ?? Self.builtInSpecs[id]
    }

    /// Reads the `gameData` table the helper addon saves into its SavedVariables.
    public init(savedVariables value: LuaValue) {
        guard let data = value["gameData"] else { return }
        for (key, entry) in data["keystones"]?.entries ?? [] {
            guard let id = key.intValue, let name = entry["name"]?.stringValue,
                  let limit = entry["timeLimit"]?.intValue else { continue }
            keystones[id] = Keystone(name: name, timeLimit: limit)
        }
        for (key, entry) in data["affixes"]?.entries ?? [] {
            guard let id = key.intValue, let name = entry.stringValue else { continue }
            affixes[id] = name
        }
        for (key, entry) in data["specs"]?.entries ?? [] {
            guard let id = key.intValue, let spec = entry["spec"]?.stringValue,
                  let className = entry["class"]?.stringValue else { continue }
            specs[id] = Spec(spec: spec, className: className)
        }
        for (key, entry) in data["cooldowns"]?.entries ?? [] {
            guard let id = key.intValue, let seconds = entry.intValue else { continue }
            cooldowns[id] = seconds
        }
    }

    static let builtInSpecs: [Int: Spec] = {
        let table: [(String, [(Int, String)])] = [
            ("Death Knight", [(250, "Blood"), (251, "Frost"), (252, "Unholy")]),
            ("Demon Hunter", [(577, "Havoc"), (581, "Vengeance")]),
            ("Druid", [(102, "Balance"), (103, "Feral"), (104, "Guardian"), (105, "Restoration")]),
            ("Evoker", [(1467, "Devastation"), (1468, "Preservation"), (1473, "Augmentation")]),
            ("Hunter", [(253, "Beast Mastery"), (254, "Marksmanship"), (255, "Survival")]),
            ("Mage", [(62, "Arcane"), (63, "Fire"), (64, "Frost")]),
            ("Monk", [(268, "Brewmaster"), (269, "Windwalker"), (270, "Mistweaver")]),
            ("Paladin", [(65, "Holy"), (66, "Protection"), (70, "Retribution")]),
            ("Priest", [(256, "Discipline"), (257, "Holy"), (258, "Shadow")]),
            ("Rogue", [(259, "Assassination"), (260, "Outlaw"), (261, "Subtlety")]),
            ("Shaman", [(262, "Elemental"), (263, "Enhancement"), (264, "Restoration")]),
            ("Warlock", [(265, "Affliction"), (266, "Demonology"), (267, "Destruction")]),
            ("Warrior", [(71, "Arms"), (72, "Fury"), (73, "Protection")]),
        ]
        var specs: [Int: Spec] = [:]
        for (className, list) in table {
            for (id, name) in list { specs[id] = Spec(spec: name, className: className) }
        }
        return specs
    }()
}

/// How a finished key went against its timer.
public enum KeystoneOutcome: Equatable, Sendable {
    /// In time; `upgrade` is how many levels the key went up (1–3).
    case timed(upgrade: Int)
    case depleted

    /// +3 within 60% of the timer, +2 within 80%, +1 within the timer.
    public init(keyTimeMs: Int, timeLimit: Int) {
        let fraction = Double(keyTimeMs) / 1000 / Double(timeLimit)
        switch fraction {
        case ...0.6: self = .timed(upgrade: 3)
        case ...0.8: self = .timed(upgrade: 2)
        case ...1.0: self = .timed(upgrade: 1)
        default: self = .depleted
        }
    }

    public var displayName: String {
        switch self {
        case .timed(let upgrade): "Timed +\(upgrade)"
        case .depleted: "Depleted"
        }
    }
}
