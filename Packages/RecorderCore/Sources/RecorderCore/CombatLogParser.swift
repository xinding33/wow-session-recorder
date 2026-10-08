import Foundation

/// The subset of combat log events the recorder cares about.
public enum CombatEvent: Sendable, Equatable {
    case logVersion(version: Int, advanced: Bool, build: String)
    case zoneChange(instanceID: Int, name: String, difficultyID: Int)
    case encounterStart(encounterID: Int, name: String, difficultyID: Int, groupSize: Int, instanceID: Int)
    case encounterEnd(encounterID: Int, name: String, difficultyID: Int, groupSize: Int, success: Bool, durationMs: Int)
    case challengeModeStart(zoneName: String, instanceID: Int, challengeModeID: Int, keystoneLevel: Int, affixIDs: [Int])
    case challengeModeEnd(instanceID: Int, success: Bool, keystoneLevel: Int, durationMs: Int)
    case arenaMatchStart(instanceID: Int, matchType: String, teamID: Int)
    case arenaMatchEnd(winningTeam: Int, durationSeconds: Int)
    /// A player (not a pet or NPC) died. `isMine` is true for the logging player.
    case playerDied(guid: String, name: String, isMine: Bool)
    /// A player's loadout, logged at encounter and key start.
    case combatantInfo(guid: String, specID: Int)
    /// The logging player cast something, which identifies who "you" are.
    case ownCast(guid: String, name: String, spellID: Int, spellName: String)
    /// The logging player or their pet interrupted `interruptedSpell`.
    case interrupt(spellName: String, interruptedSpell: String, targetName: String)
    /// The logging player or their pet removed `auraName` from `targetName`.
    case dispel(spellName: String, auraName: String, targetName: String, targetIsHostile: Bool)
    /// Anyone cast Bloodlust or an equivalent.
    case bloodlust(sourceName: String, spellName: String)
    /// A player was resurrected. Includes out-of-combat resurrections.
    case resurrect(sourceName: String, targetName: String, spellID: Int, spellName: String)
    /// Health of a hostile NPC, from the advanced-logging fields of its own attacks and casts.
    case hostileHealth(guid: String, current: Int, max: Int)
}

public struct CombatLogEntry: Sendable, Equatable {
    public var date: Date
    public var event: CombatEvent
    /// Where the line is in the log file, when read from one.
    public var position: LogPosition?

    public init(date: Date, event: CombatEvent, position: LogPosition? = nil) {
        self.date = date
        self.event = event
        self.position = position
    }
}

/// Parses lines of `WoWCombatLog-*.txt`.
///
/// A line looks like `5/20/2026 13:34:18.056-7  ENCOUNTER_START,2563,"Overgrown Ancient",8,5,2526`:
/// a timestamp, two spaces, the event name, then comma-separated fields.
public enum CombatLogParser {
    private static let interestingEvents: Set<Substring> = [
        "COMBAT_LOG_VERSION", "ZONE_CHANGE", "ENCOUNTER_START", "ENCOUNTER_END",
        "CHALLENGE_MODE_START", "CHALLENGE_MODE_END", "ARENA_MATCH_START", "ARENA_MATCH_END",
        "UNIT_DIED", "COMBATANT_INFO", "SPELL_CAST_SUCCESS",
        "SPELL_INTERRUPT", "SPELL_DISPEL", "SPELL_STOLEN", "SPELL_RESURRECT",
        "SWING_DAMAGE", "SWING_DAMAGE_LANDED", "SPELL_DAMAGE", "RANGE_DAMAGE", "SPELL_PERIODIC_DAMAGE",
    ]

    /// Returns `nil` for malformed lines and for events the recorder ignores.
    public static func parse(line: some StringProtocol, position: LogPosition? = nil) -> CombatLogEntry? {
        let line = Substring(line)
        guard let separator = line.range(of: "  ") else { return nil }
        let body = line[separator.upperBound...]
        let eventName = body.prefix { $0 != "," }
        // Cheap rejection of the ~99% of lines that are damage/heal/aura events.
        guard interestingEvents.contains(eventName) else { return nil }

        let fields = splitFields(body)
        guard let event = makeEvent(name: eventName, fields: fields) else { return nil }
        guard let date = CombatTimestamp.parse(line[..<separator.lowerBound]) else { return nil }
        return CombatLogEntry(date: date, event: event, position: position)
    }

    private static func makeEvent(name: Substring, fields f: [Substring]) -> CombatEvent? {
        func int(_ i: Int) -> Int? { i < f.count ? Int(f[i]) : nil }
        func str(_ i: Int) -> String? { i < f.count ? unquote(f[i]) : nil }

        switch name {
        case "COMBAT_LOG_VERSION":
            // COMBAT_LOG_VERSION,22,ADVANCED_LOG_ENABLED,1,BUILD_VERSION,12.0.5,PROJECT_ID,1
            guard let version = int(1) else { return nil }
            return .logVersion(version: version, advanced: int(3) == 1, build: str(5) ?? "")
        case "ZONE_CHANGE":
            // ZONE_CHANGE,2526,"Algeth'ar Academy",23
            guard let id = int(1), let zone = str(2) else { return nil }
            return .zoneChange(instanceID: id, name: zone, difficultyID: int(3) ?? 0)
        case "ENCOUNTER_START":
            // ENCOUNTER_START,2563,"Overgrown Ancient",8,5,2526
            guard let id = int(1), let boss = str(2) else { return nil }
            return .encounterStart(encounterID: id, name: boss, difficultyID: int(3) ?? 0,
                                   groupSize: int(4) ?? 0, instanceID: int(5) ?? 0)
        case "ENCOUNTER_END":
            // ENCOUNTER_END,2563,"Overgrown Ancient",8,5,1,75006
            guard let id = int(1), let boss = str(2) else { return nil }
            return .encounterEnd(encounterID: id, name: boss, difficultyID: int(3) ?? 0,
                                 groupSize: int(4) ?? 0, success: int(5) == 1, durationMs: int(6) ?? 0)
        case "CHALLENGE_MODE_START":
            // CHALLENGE_MODE_START,"Skyreach",1209,161,11,[162,10,9]
            guard let zone = str(1), let instanceID = int(2) else { return nil }
            let affixes = f.count > 5 ? f[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",").compactMap { Int($0) } : []
            return .challengeModeStart(zoneName: zone, instanceID: instanceID,
                                       challengeModeID: int(3) ?? 0, keystoneLevel: int(4) ?? 0, affixIDs: affixes)
        case "CHALLENGE_MODE_END":
            // CHALLENGE_MODE_END,1209,1,11,1101714,347.908173,3445.950195
            guard let instanceID = int(1) else { return nil }
            return .challengeModeEnd(instanceID: instanceID, success: int(2) == 1,
                                     keystoneLevel: int(3) ?? 0, durationMs: int(4) ?? 0)
        case "ARENA_MATCH_START":
            // ARENA_MATCH_START,instanceID,unknown,matchType,teamID
            guard let instanceID = int(1) else { return nil }
            return .arenaMatchStart(instanceID: instanceID, matchType: str(3) ?? "", teamID: int(4) ?? -1)
        case "ARENA_MATCH_END":
            // ARENA_MATCH_END,winningTeam,duration,newRatingTeam1,newRatingTeam2
            guard let winner = int(1) else { return nil }
            return .arenaMatchEnd(winningTeam: winner, durationSeconds: int(2) ?? 0)
        case "UNIT_DIED":
            // UNIT_DIED,src GUID,src name,src flags,src raid flags,dest GUID,"dest name",dest flags,dest raid flags,unconsciousOnDeath
            guard f.count >= 8 else { return nil }
            let guid = f[5]
            guard guid.hasPrefix("Player-") else { return nil }
            // Feign Death and similar "unconscious" deaths aren't real deaths.
            if f.count >= 10, f[9] == "1" { return nil }
            let flags = UInt32(f[7].dropFirst(2), radix: 16) ?? 0
            return .playerDied(guid: String(guid), name: unquote(f[6]), isMine: flags & affiliationMine != 0)
        case "COMBATANT_INFO":
            // COMBATANT_INFO,playerGUID,faction,str,agi,sta,int,dodge,parry,block,crit×3,speed,
            // leech,haste×3,avoidance,mastery,vers×3,armor,currentSpecID,[talents],...
            guard f.count > 25, f[1].hasPrefix("Player-"), let spec = int(25) else { return nil }
            return .combatantInfo(guid: String(f[1]), specID: spec)
        case "SPELL_CAST_SUCCESS" where f.count > 10 && int(9).map(bloodlustSpellIDs.contains) == true:
            // SPELL_CAST_SUCCESS,src GUID,"src name",src flags,src raid flags,dest ×4,spell ID,"spell name",school,...
            return .bloodlust(sourceName: unquote(f[2]), spellName: unquote(f[10]))
        case "SPELL_CAST_SUCCESS" where f.count > 10 && f[1].hasPrefix("Player-") && hasFlag(f[3], affiliationMine):
            return .ownCast(guid: String(f[1]), name: unquote(f[2]), spellID: int(9) ?? 0, spellName: unquote(f[10]))
        case "SPELL_INTERRUPT":
            // SPELL_INTERRUPT,src ×4,dest ×4,spell ID,"spell name",school,interrupted ID,"interrupted name",school
            guard f.count > 13, hasFlag(f[3], affiliationMine) else { return nil }
            return .interrupt(spellName: unquote(f[10]), interruptedSpell: unquote(f[13]), targetName: unquote(f[6]))
        case "SPELL_DISPEL", "SPELL_STOLEN":
            // SPELL_DISPEL,src ×4,dest ×4,spell ID,"spell name",school,aura ID,"aura name",school,BUFF|DEBUFF
            guard f.count > 13, hasFlag(f[3], affiliationMine) else { return nil }
            return .dispel(spellName: unquote(f[10]), auraName: unquote(f[13]), targetName: unquote(f[6]),
                           targetIsHostile: hasFlag(f[7], reactionHostile))
        case "SPELL_RESURRECT":
            // SPELL_RESURRECT,src ×4,dest ×4,spell ID,"spell name",school
            guard f.count > 10, f[5].hasPrefix("Player-") else { return nil }
            return .resurrect(sourceName: unquote(f[2]), targetName: unquote(f[6]),
                              spellID: int(9) ?? 0, spellName: unquote(f[10]))
        default:
            return hostileHealth(name: name, fields: f)
        }
    }

    /// Advanced combat logging appends the acting unit's state after the event prefix:
    /// `infoGUID, ownerGUID, currentHP, maxHP, ...`. For damage and casts the info unit is
    /// the source, so a boss's own attacks report its health.
    private static func hostileHealth(name: Substring, fields f: [Substring]) -> CombatEvent? {
        // Swing events have no spell prefix (id, name, school) before the advanced fields.
        let advancedStart = name.hasPrefix("SWING") ? 9 : 12
        guard f.count > advancedStart + 3 else { return nil }
        let infoGUID = f[advancedStart]
        guard infoGUID == f[1], infoGUID.hasPrefix("Creature-") || infoGUID.hasPrefix("Vehicle-"),
              hasFlag(f[3], reactionHostile),
              let current = Int(f[advancedStart + 2]), let max = Int(f[advancedStart + 3]), max > 0
        else { return nil }
        return .hostileHealth(guid: String(infoGUID), current: current, max: max)
    }

    private static func hasFlag(_ field: Substring, _ flag: UInt32) -> Bool {
        (UInt32(field.dropFirst(2), radix: 16) ?? 0) & flag != 0
    }

    /// Bloodlust, Heroism, Time Warp, Primal Rage (both IDs), Fury of the Aspects, Harrier's Cry
    /// and the leatherworking drums.
    public static let bloodlustSpellIDs: Set<Int> = [
        2825, 32182, 80353, 264667, 272678, 390386, 466904,
        230935, 256740, 309658, 381301, 444257,
    ]

    /// Resurrections usable in combat: Rebirth, Raise Ally, Intercession, Soulstone and the
    /// engineering ones.
    public static let battleResSpellIDs: Set<Int> = [
        20484, 61999, 391054, 20707, 95750, 345130, 384893, 385403,
    ]

    /// COMBATLOG_OBJECT_REACTION_HOSTILE
    private static let reactionHostile: UInt32 = 0x40

    /// COMBATLOG_OBJECT_AFFILIATION_MINE
    private static let affiliationMine: UInt32 = 0x1

    /// Splits on top-level commas, keeping quoted strings and bracketed lists intact.
    static func splitFields(_ s: Substring) -> [Substring] {
        var fields: [Substring] = []
        var depth = 0
        var inQuotes = false
        var start = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inQuotes {
                if c == "\"" { inQuotes = false }
            } else {
                switch c {
                case "\"": inQuotes = true
                case "[", "(": depth += 1
                case "]", ")": depth -= 1
                case "," where depth == 0:
                    fields.append(s[start..<i])
                    start = s.index(after: i)
                default: break
                }
            }
            i = s.index(after: i)
        }
        fields.append(s[start...])
        return fields
    }

    static func unquote(_ s: Substring) -> String {
        if s.count >= 2, s.first == "\"", s.last == "\"" {
            return String(s.dropFirst().dropLast())
        }
        return String(s)
    }
}

/// Parses combat log timestamps such as `5/20/2026 13:31:34.075-7`.
///
/// Retail logs include the year and a UTC offset in hours. Older formats without either
/// fall back to the current year and the local time zone.
public enum CombatTimestamp {
    public static func parse(_ s: some StringProtocol) -> Date? {
        let s = Substring(s)
        guard let space = s.firstIndex(of: " ") else { return nil }
        let dateParts = s[..<space].split(separator: "/")
        guard dateParts.count >= 2,
              let month = Int(dateParts[0]),
              let day = Int(dateParts[1])
        else { return nil }
        let year = dateParts.count >= 3 ? Int(dateParts[2]) : nil

        var time = s[s.index(after: space)...]
        var timeZone = TimeZone.current
        if let sign = time.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            if let hours = Double(time[sign...]),
               let tz = TimeZone(secondsFromGMT: Int((hours * 3600).rounded())) {
                timeZone = tz
            }
            time = time[..<sign]
        }

        let clock = time.split(separator: ":")
        guard clock.count == 3,
              let hour = Int(clock[0]),
              let minute = Int(clock[1]),
              let seconds = Double(clock[2])
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year ?? calendar.component(.year, from: Date())
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = Int(seconds)
        guard let whole = calendar.date(from: components) else { return nil }
        return whole.addingTimeInterval(seconds - seconds.rounded(.down))
    }
}
