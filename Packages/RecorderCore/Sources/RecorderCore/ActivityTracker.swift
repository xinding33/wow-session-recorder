import Foundation

/// Turns a stream of combat log events into labelled activities.
///
/// The tracker is a pure state machine: feed it entries and it returns the activities that
/// were created or changed, which the caller persists. Footage is recorded continuously, so the
/// tracker only has to describe *when* things happened, not start or stop capture.
public struct ActivityTracker: Sendable {
    public struct Options: Sendable {
        /// How much footage before a bookmark a standalone bookmark clip covers.
        public var bookmarkClipBefore: TimeInterval = 30
        /// How much footage after a bookmark a standalone bookmark clip covers.
        public var bookmarkClipAfter: TimeInterval = 10
        /// How long a bookmark clip runs when there was no footage before the bookmark.
        public var forwardClipLength: TimeInterval = 60
        /// Activities left open longer than this are closed as abandoned.
        public var maxActivityDuration: TimeInterval = 3 * 60 * 60
        /// The player's major cooldowns (spell IDs), marked when cast. Learned by the helper addon.
        public var cooldownSpellIDs: Set<Int> = []

        public init() {}
    }

    public var options: Options
    /// The open combat-log-driven activity (encounter, key, or arena match).
    public private(set) var current: Activity?
    /// The open manual clip, if the player started one with the hotkey.
    public private(set) var manualClip: Activity?
    /// The most recent standalone bookmark clip, so rapid presses extend it instead of
    /// creating a pile of overlapping clips.
    private var lastBookmarkClip: Activity?

    private var zone: (instanceID: Int, name: String, difficultyID: Int)?
    /// The open activity spans a whole run (a key or a delve), so bosses inside it are markers
    /// rather than activities of their own.
    private var currentIsRun = false
    /// A boss died during the open delve run.
    private var runBossKilled = false
    private var currentEncounterID: Int?
    private var keyInstanceID: Int?
    private var arenaTeamID: Int?

    /// The logging player, learned from their own casts.
    public private(set) var playerGUID: String?
    private var playerName: String?
    /// Specs logged for the current activity's group (`COMBATANT_INFO` follows every start).
    private var combatants: [String: Int] = [:]
    /// Hostile NPCs seen during the open encounter: max health and the lowest % they reached.
    private var encounterUnits: [String: (maxHP: Int, lowestPercent: Double)] = [:]
    /// Position of the line being handled, for activities' log ranges.
    private var position: LogPosition?

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Where the player is

    /// Inside a dungeon, raid or delve, going by the last zone change in the log.
    ///
    /// Instance ID 0 is the open world. WoW sometimes carries the previous difficulty over when
    /// you leave (`ZONE_CHANGE,0,"Silvermoon City",23`), so the difficulty alone isn't enough.
    public var isInInstance: Bool {
        zone.map { $0.instanceID != 0 && Difficulty.isInstance($0.difficultyID) } ?? false
    }

    /// Whether footage is needed right now: in an instance, or something is in progress
    /// (a key you stepped out of, an arena match, a manual clip).
    public var wantsRecording: Bool {
        isInInstance || current != nil || manualClip != nil
    }

    /// Learns the current zone without touching activities, e.g. from the end of a log that was
    /// already being written when the app started.
    public mutating func seedZone(from entry: CombatLogEntry) {
        if case let .zoneChange(instanceID, name, difficultyID) = entry.event {
            zone = (instanceID, name, difficultyID)
        }
    }

    // MARK: - Combat log

    public mutating func handle(_ entry: CombatLogEntry) -> [Activity] {
        switch entry.event {
        case let .ownCast(guid, name, spellID, spellName):
            var changed: [Activity] = []
            if guid != playerGUID {
                playerGUID = guid
                playerName = Self.shortName(name)
                changed += refreshDetails()
            }
            // Rebirth and friends are marked when the resurrection lands instead.
            if options.cooldownSpellIDs.contains(spellID), !CombatLogParser.battleResSpellIDs.contains(spellID) {
                changed += addMarker(Marker(date: entry.date, kind: .cooldown, label: spellName))
            }
            return changed
        case let .combatantInfo(guid, specID):
            combatants[guid] = specID
            return refreshDetails()
        case let .hostileHealth(guid, current, max):
            guard currentEncounterID != nil else { return [] }
            let percent = Double(current) / Double(max) * 100
            let lowest = min(percent, encounterUnits[guid]?.lowestPercent ?? 100)
            encounterUnits[guid] = (Swift.max(max, encounterUnits[guid]?.maxHP ?? 0), lowest)
            return []
        default:
            break
        }

        position = entry.position
        let previousID = current?.id
        var changed = handleActivityEvent(entry)
        if var open = current, open.id != previousID {
            // A new activity just started; the group's loadouts follow in the next lines.
            combatants = [:]
            if let position {
                open.log = LogRange(fileName: position.fileName, startOffset: position.offset)
            }
            current = open
            if let index = changed.lastIndex(where: { $0.id == open.id }) { changed[index] = open }
            changed += refreshDetails()
        }
        return changed
    }

    /// Fills in the player's character, spec and group from what's been logged so far.
    private mutating func refreshDetails() -> [Activity] {
        guard var open = current else { return [] }
        let before = open
        if let playerName { open.character = playerName }
        if let playerGUID, let spec = combatants[playerGUID] { open.specID = spec }
        if !combatants.isEmpty { open.groupSpecIDs = combatants.values.sorted() }
        guard open != before else { return [] }
        current = open
        return [open]
    }

    /// Lowest health % of the boss, taken as the hostile NPC with the most max health.
    private var bossHealthPercent: Double? {
        encounterUnits.values.max { $0.maxHP < $1.maxHP }?.lowestPercent
    }

    private mutating func handleActivityEvent(_ entry: CombatLogEntry) -> [Activity] {
        var changed: [Activity] = []
        let date = entry.date

        if let open = current, date.timeIntervalSince(open.start) > options.maxActivityDuration {
            changed += finishCurrent(at: date, result: .abandoned)
        }

        switch entry.event {
        case .logVersion, .ownCast, .combatantInfo, .hostileHealth:
            break

        case let .interrupt(_, interruptedSpell, _):
            changed += addMarker(Marker(date: date, kind: .interrupt, label: "Interrupted \(interruptedSpell)"))

        case let .dispel(_, auraName, targetName, targetIsHostile):
            let label = targetIsHostile
                ? "Purged \(auraName)"
                : "Dispelled \(auraName) from \(displayName(targetName))"
            changed += addMarker(Marker(date: date, kind: .dispel, label: label))

        case let .bloodlust(sourceName, spellName):
            changed += addMarker(Marker(date: date, kind: .bloodlust, label: "\(spellName) (\(displayName(sourceName)))"))

        case let .resurrect(sourceName, targetName, spellID, spellName):
            // Out of combat anyone can resurrect, so outside a boss fight only battle res spells count.
            guard currentEncounterID != nil || CombatLogParser.battleResSpellIDs.contains(spellID) else { break }
            changed += addMarker(Marker(date: date, kind: .battleRes,
                                        label: "\(spellName) on \(displayName(targetName)) (\(displayName(sourceName)))"))

        case let .zoneChange(instanceID, name, difficultyID):
            defer { zone = (instanceID, name, difficultyID) }
            let isNewInstance = instanceID != zone?.instanceID

            // WoW sometimes names the zone "UNKNOWN AREA" first, then logs the real name.
            if !isNewInstance, var run = current, currentIsRun, run.kind == .delve, run.title != name {
                run.title = name
                current = run
                changed.append(run)
            }

            if let open = current, isNewInstance {
                switch open.kind {
                case .mythicPlus:
                    // Leaving to the open world mid-key is normal (e.g. repairing); entering a
                    // different instance is not.
                    if instanceID != 0, instanceID != keyInstanceID {
                        changed += finishCurrent(at: date, result: .abandoned)
                    }
                case .delve where currentIsRun:
                    changed += finishCurrent(at: date, result: runBossKilled ? .completed : .abandoned)
                default:
                    changed += finishCurrent(at: date, result: .unknown)
                }
            }

            // A delve is recorded as one run from entering to leaving, like a key.
            if isNewInstance, instanceID != 0, Difficulty.delve.contains(difficultyID), current == nil {
                let run = Activity(kind: .delve, title: name, subtitle: "Delve", start: date)
                current = run
                currentIsRun = true
                changed.append(run)
            }

        case let .encounterStart(encounterID, name, difficultyID, _, _):
            encounterUnits = [:]
            if var run = current, currentIsRun {
                run.markers.append(Marker(date: date, kind: .bossPull, label: "Pull: \(name)"))
                current = run
                currentEncounterID = encounterID
                changed.append(run)
            } else {
                changed += finishCurrent(at: date, result: .unknown)
                let subtitle = [zone?.name, Difficulty.name(for: difficultyID)]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                var activity = Activity(
                    kind: Difficulty.activityKind(for: difficultyID),
                    title: name,
                    subtitle: subtitle,
                    start: date,
                    markers: [Marker(date: date, kind: .bossPull, label: "Pull: \(name)")]
                )
                activity.encounterID = encounterID
                activity.difficultyID = difficultyID
                current = activity
                currentEncounterID = encounterID
                changed.append(activity)
            }

        case let .encounterEnd(encounterID, name, _, _, success, _):
            defer { encounterUnits = [:] }
            guard var open = current else { break }
            let health = success ? nil : bossHealthPercent
            let wipeLabel = health.map { "Wipe: \(name) (\(Int($0.rounded()))%)" } ?? "Wipe: \(name)"
            let marker = Marker(date: date, kind: success ? .bossKill : .bossWipe,
                                label: success ? "Kill: \(name)" : wipeLabel)
            if currentIsRun {
                open.markers.append(marker)
                current = open
                currentEncounterID = nil
                if success { runBossKilled = true }
                changed.append(open)
            } else if currentEncounterID == encounterID {
                open.markers.append(marker)
                open.bossHealthPercent = health
                current = open
                changed += finishCurrent(at: date, result: success ? .kill : .wipe)
            }

        case let .challengeModeStart(zoneName, instanceID, challengeModeID, keystoneLevel, affixIDs):
            changed += finishCurrent(at: date, result: .abandoned)
            var key = Activity(kind: .mythicPlus, title: "\(zoneName) +\(keystoneLevel)",
                               subtitle: "Mythic+", start: date)
            key.challengeModeID = challengeModeID
            key.keystoneLevel = keystoneLevel
            key.affixIDs = affixIDs
            current = key
            currentIsRun = true
            keyInstanceID = instanceID
            changed.append(current!)

        case let .challengeModeEnd(_, success, _, durationMs):
            // WoW logs a stray CHALLENGE_MODE_END (all zeros) right before every key start.
            guard var key = current, key.kind == .mythicPlus else { break }
            if success, durationMs > 0 {
                key.subtitle = "Mythic+ · \(Self.formatDuration(Double(durationMs) / 1000))"
                key.keyTimeMs = durationMs
            }
            current = key
            changed += finishCurrent(at: date, result: success ? .completed : .abandoned)

        case let .arenaMatchStart(_, matchType, teamID):
            changed += finishCurrent(at: date, result: .unknown)
            let title = matchType.isEmpty ? "Arena" : "Arena \(matchType)"
            current = Activity(kind: .arena, title: title, subtitle: zone?.name ?? "", start: date)
            arenaTeamID = teamID
            changed.append(current!)

        case let .arenaMatchEnd(winningTeam, _):
            guard current?.kind == .arena else { break }
            let result: ActivityResult = arenaTeamID.map { $0 == winningTeam ? .win : .loss } ?? .unknown
            changed += finishCurrent(at: date, result: result)

        case let .playerDied(guid, name, isMine):
            changed += addMarker(Marker(date: date, kind: isMine ? .playerDeath : .death,
                                        label: isMine ? "You died" : "\(Self.shortName(name)) died",
                                        unitGUID: guid, log: position))
        }
        return changed
    }

    /// Adds a marker to the open activity and manual clip. Outside both it's dropped: there's
    /// nothing to show it on.
    private mutating func addMarker(_ marker: Marker) -> [Activity] {
        var changed: [Activity] = []
        if var open = current {
            open.markers.append(marker)
            current = open
            changed.append(open)
        }
        if var clip = manualClip {
            clip.markers.append(marker)
            manualClip = clip
            changed.append(clip)
        }
        return changed
    }

    // MARK: - Hotkeys

    /// Drops a bookmark into whatever is open, or creates a short clip around it if nothing is.
    ///
    /// Pass `hasFootageBefore: false` when nothing was being recorded: the clip then starts at
    /// the bookmark and runs forward instead of reaching back.
    public mutating func bookmark(at date: Date, hasFootageBefore: Bool = true) -> [Activity] {
        let marker = Marker(date: date, kind: .bookmark, label: "Bookmark")
        let changed = addMarker(marker)
        guard changed.isEmpty else { return changed }

        if var clip = lastBookmarkClip, let end = clip.end, date <= end {
            clip.markers.append(marker)
            clip.end = max(end, date.addingTimeInterval(options.bookmarkClipAfter))
            lastBookmarkClip = clip
            return [clip]
        }
        let clip = Activity(
            kind: .clip,
            title: "Bookmark",
            subtitle: zone?.name ?? "",
            start: hasFootageBefore ? date.addingTimeInterval(-options.bookmarkClipBefore) : date,
            end: date.addingTimeInterval(hasFootageBefore ? options.bookmarkClipAfter : options.forwardClipLength),
            result: .unknown,
            markers: [marker]
        )
        lastBookmarkClip = clip
        return [clip]
    }

    /// Starts a manual clip, or ends the open one.
    public mutating func toggleManualClip(at date: Date) -> [Activity] {
        if var clip = manualClip {
            clip.end = date
            clip.result = .unknown
            manualClip = nil
            return [clip]
        }
        let clip = Activity(kind: .clip, title: "Clip", subtitle: zone?.name ?? "", start: date)
        manualClip = clip
        return [clip]
    }

    /// WoW starts a new log file whenever logging is re-enabled (relog, disconnect, `/combatlog`).
    /// An open encounter can't be resolved across files, but a run (key or delve) can: its end
    /// arrives in the new file.
    public mutating func logFileChanged(at date: Date) -> [Activity] {
        guard current != nil, !currentIsRun else { return [] }
        return finishCurrent(at: date, result: .unknown)
    }

    /// Closes everything, e.g. when WoW quits.
    public mutating func endAll(at date: Date) -> [Activity] {
        var changed = finishCurrent(at: date, result: .abandoned)
        if manualClip != nil {
            changed += toggleManualClip(at: date)
        }
        zone = nil
        return changed
    }

    // MARK: - Helpers

    private mutating func finishCurrent(at date: Date, result: ActivityResult) -> [Activity] {
        guard var open = current else { return [] }
        open.end = max(date, open.start)
        open.result = result
        if let position, open.log?.fileName == position.fileName {
            open.log?.endOffset = position.offset
        }
        if open.kind == .delve, currentIsRun, result == .completed {
            open.subtitle = "Delve · \(Self.formatDuration(open.end!.timeIntervalSince(open.start)))"
        }
        current = nil
        currentIsRun = false
        runBossKilled = false
        currentEncounterID = nil
        keyInstanceID = nil
        arenaTeamID = nil
        return [open]
    }

    /// A player's name for a marker label: "you" for the logging player, otherwise without realm.
    private func displayName(_ name: String) -> String {
        let short = Self.shortName(name)
        return short == playerName ? "you" : short
    }

    /// `"Leafwhisper-Area52-US"` → `"Leafwhisper"`
    static func shortName(_ name: String) -> String {
        String(name.prefix { $0 != "-" })
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
