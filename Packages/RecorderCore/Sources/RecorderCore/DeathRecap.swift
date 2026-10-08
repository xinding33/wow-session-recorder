import Foundation

/// What hit a player in the seconds before they died, and the healing they got, read back from
/// the combat log on demand. The live parser skips damage and healing to stay cheap.
public struct DeathRecap: Sendable, Equatable {
    public struct Event: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case damage
            case heal
            case instakill
        }

        public var id: Int
        public var date: Date
        public var kind: Kind
        public var source: String
        public var ability: String
        /// Damage taken, or healing that wasn't overhealing.
        public var amount: Int
        public var overkill: Int
        public var absorbed: Int
        public var isCritical: Bool
        /// Health right after the event, when Advanced Combat Logging recorded it.
        public var health: Int?
        public var maxHealth: Int?

        public var healthPercent: Double? {
            guard let health, let maxHealth, maxHealth > 0 else { return nil }
            return Double(health) / Double(maxHealth) * 100
        }
    }

    /// Oldest first.
    public var events: [Event]

    public var killingBlow: Event? { events.last { $0.kind != .heal } }
    public var damageTaken: Int { events.filter { $0.kind == .damage }.reduce(0) { $0 + $1.amount } }
    public var healingReceived: Int { events.filter { $0.kind == .heal }.reduce(0) { $0 + $1.amount } }

    /// How far back a recap looks.
    public static let window: TimeInterval = 10

    /// Builds the recap for `unitGUID` from raw log lines around its death.
    public static func build(lines: [String], unitGUID: String, death: Date, window: TimeInterval = window) -> DeathRecap {
        let from = death.addingTimeInterval(-window)
        // The killing blow can be stamped a hair after UNIT_DIED when WoW writes lines out of order.
        let to = death.addingTimeInterval(0.25)
        var events: [Event] = []
        var swings: [Event] = []

        for line in lines where line.contains(unitGUID) {
            guard let separator = line.range(of: "  ") else { continue }
            let body = line[separator.upperBound...]
            let f = CombatLogParser.splitFields(body)
            guard f.count > 8, f[5] == unitGUID else { continue }
            let name = f[0]
            guard Self.recapEvents.contains(name),
                  let date = CombatTimestamp.parse(line[..<separator.lowerBound]),
                  date >= from, date <= to,
                  var event = Self.event(name: name, fields: f, unitGUID: unitGUID)
            else { continue }
            event.date = date
            if name == "SWING_DAMAGE" { swings.append(event) } else { events.append(event) }
        }

        // Advanced logging writes every melee hit twice: SWING_DAMAGE (with the attacker's health)
        // and SWING_DAMAGE_LANDED (with the target's). Keep a SWING_DAMAGE only if it has no twin.
        for swing in swings where !events.contains(where: {
            $0.ability == swing.ability && $0.source == swing.source && $0.amount == swing.amount
                && abs($0.date.timeIntervalSince(swing.date)) < 1
        }) {
            events.append(swing)
        }

        events.sort { $0.date < $1.date }
        for index in events.indices { events[index].id = index }
        return DeathRecap(events: events)
    }

    /// Where the advanced fields that start at `start` end, or `nil` without advanced logging.
    ///
    /// The block's length has changed between game versions (17 fields in 11.x, 19 in 12.0), but
    /// it always ends with the unit's position: x, y (decimals), map ID, facing (decimal), level.
    static func advancedEnd(_ f: [Substring], start: Int) -> Int? {
        guard f.count > start + 3, f[start].contains("-") || f[start] == "0000000000000000" else { return nil }
        var i = start + 4
        while i + 4 < f.count, i < start + 24 {
            if f[i].contains("."), f[i + 1].contains("."), !f[i + 2].contains("."), f[i + 3].contains(".") {
                return i + 5
            }
            i += 1
        }
        return nil
    }

    private static let recapEvents: Set<Substring> = [
        "SWING_DAMAGE", "SWING_DAMAGE_LANDED", "SPELL_DAMAGE", "SPELL_PERIODIC_DAMAGE", "RANGE_DAMAGE",
        "SPELL_BUILDING_DAMAGE", "ENVIRONMENTAL_DAMAGE", "SPELL_INSTAKILL", "SPELL_HEAL", "SPELL_PERIODIC_HEAL",
    ]

    /// `fields[0]` is the event name, 1–8 the source and destination, then the event's own fields.
    private static func event(name: Substring, fields f: [Substring], unitGUID: String) -> Event? {
        func int(_ i: Int) -> Int { i < f.count ? Int(f[i]) ?? 0 : 0 }
        let source = f[1] == "0000000000000000" ? "Environment" : ActivityTracker.shortName(CombatLogParser.unquote(f[2]))

        // Swing and environmental events have no spell prefix (ID, name, school) before the
        // advanced fields; the rest do.
        let isSwing = name.hasPrefix("SWING")
        let isEnvironment = name == "ENVIRONMENTAL_DAMAGE"
        let advancedStart = isSwing || isEnvironment ? 9 : 12
        var ability = isSwing ? "Melee" : f.count > 10 ? CombatLogParser.unquote(f[10]) : "Unknown"

        if name == "SPELL_INSTAKILL" {
            return Event(id: 0, date: .distantPast, kind: .instakill, source: source, ability: ability,
                         amount: 0, overkill: 0, absorbed: 0, isCritical: false)
        }

        // Advanced Combat Logging inserts fields describing one unit, starting with its GUID.
        let advancedEnd = Self.advancedEnd(f, start: advancedStart)
        var suffix = advancedEnd ?? advancedStart
        var health: Int?, maxHealth: Int?
        if advancedEnd != nil, f[advancedStart] == unitGUID {
            health = Int(f[advancedStart + 2])
            maxHealth = Int(f[advancedStart + 3])
        }
        if isEnvironment {
            ability = suffix < f.count ? String(f[suffix]) : "Environment"
            suffix += 1
        }
        guard suffix < f.count else { return nil }

        if name.hasSuffix("_HEAL") {
            // amount, base amount, overhealing, absorbed, critical
            let effective = int(suffix) - max(int(suffix + 2), 0)
            guard effective > 0 else { return nil }
            return Event(id: 0, date: .distantPast, kind: .heal, source: source, ability: ability,
                         amount: effective, overkill: 0, absorbed: max(int(suffix + 3), 0),
                         isCritical: suffix + 4 < f.count && f[suffix + 4] == "1",
                         health: health, maxHealth: maxHealth)
        }
        // amount, base amount, overkill, school, resisted, blocked, absorbed, critical
        return Event(id: 0, date: .distantPast, kind: .damage, source: source, ability: ability,
                     amount: int(suffix), overkill: max(int(suffix + 2), 0), absorbed: max(int(suffix + 6), 0),
                     isCritical: suffix + 7 < f.count && f[suffix + 7] == "1",
                     health: health, maxHealth: maxHealth)
    }
}

/// Finding and reading parts of `WoWCombatLog-*.txt` files after the fact.
public enum CombatLogFiles {
    /// When logging started, from a name like `WoWCombatLog-100626_225830.txt` (local time).
    public static func startDate(fileName: String, calendar: Calendar = .current) -> Date? {
        guard fileName.hasPrefix("WoWCombatLog-"), fileName.hasSuffix(".txt") else { return nil }
        let stamp = fileName.dropFirst("WoWCombatLog-".count).prefix(13)
        let digits = stamp.filter(\.isNumber)
        guard stamp.count == 13, digits.count == 12 else { return nil }
        let n = digits.map { Int(String($0))! }
        func pair(_ i: Int) -> Int { n[i] * 10 + n[i + 1] }
        var components = DateComponents()
        components.month = pair(0)
        components.day = pair(2)
        components.year = 2000 + pair(4)
        components.hour = pair(6)
        components.minute = pair(8)
        components.second = pair(10)
        return calendar.date(from: components)
    }

    /// The log that was being written at `date`: the newest one started before it.
    public static func file(at date: Date, in directory: URL) -> URL? {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .compactMap { url in startDate(fileName: url.lastPathComponent).map { (url, $0) } }
            .filter { $0.1 <= date }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Complete lines covering `from`…`to`, reading outward from `anchor`: the start of a line
    /// near `to`, such as the death's own line. Without one, the file is searched by timestamp.
    public static func lines(in url: URL, anchor: UInt64?, from: Date, to: Date) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let anchor = min(anchor ?? offset(before: to, in: handle, size: size), size)

        // Lines can be written a little out of order, so read a margin past `to`.
        var lines = try readLines(handle, from: anchor, to: min(size, anchor + (1 << 20)))

        // Busy raid logs write megabytes in ten seconds; widen the window until it reaches `from`.
        var back: UInt64 = 1 << 20
        while true {
            let start = anchor > back ? anchor - back : 0
            var before = try readLines(handle, from: start, to: anchor)
            // The chunk starts mid-line unless it starts at the top of the file.
            if start > 0, !before.isEmpty { before.removeFirst() }
            let reachesBack = before.first.flatMap(timestamp).map { $0 < from.addingTimeInterval(-1) } ?? false
            if start == 0 || reachesBack || back >= 64 << 20 {
                lines.insert(contentsOf: before, at: 0)
                return lines
            }
            back *= 4
        }
    }

    /// A line-start offset at or shortly before the first line stamped `date` or later.
    static func offset(before date: Date, in handle: FileHandle, size: UInt64) -> UInt64 {
        var low: UInt64 = 0, high = size
        while high - low > 64 << 10 {
            let mid = low + (high - low) / 2
            // The first line read from `mid` is partial; the second is the first whole one.
            guard let lines = try? readLines(handle, from: mid, to: min(size, mid + (8 << 10))),
                  let stamp = lines.dropFirst().first.flatMap(timestamp)
            else { high = mid; continue }
            if stamp < date { low = mid } else { high = mid }
        }
        guard low > 0 else { return 0 }
        guard (try? handle.seek(toOffset: low)) != nil,
              let chunk = try? handle.read(upToCount: 8 << 10),
              let newline = chunk.firstIndex(of: 0x0A) else { return low }
        return low + UInt64(newline - chunk.startIndex) + 1
    }

    /// Lines in `start..<end`. A line cut off at `end` is dropped.
    private static func readLines(_ handle: FileHandle, from start: UInt64, to end: UInt64) throws -> [String] {
        guard end > start else { return [] }
        try handle.seek(toOffset: start)
        var buffer = LineBuffer()
        return buffer.append(try handle.read(upToCount: Int(end - start)) ?? Data())
    }

    private static func timestamp(_ line: String) -> Date? {
        guard let separator = line.range(of: "  ") else { return nil }
        return CombatTimestamp.parse(line[..<separator.lowerBound])
    }
}
