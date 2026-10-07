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
    private var currentEncounterID: Int?
    private var keyInstanceID: Int?
    private var arenaTeamID: Int?

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Where the player is

    /// Inside a dungeon, raid or delve, going by the last zone change in the log.
    public var isInInstance: Bool {
        zone.map { Difficulty.isInstance($0.difficultyID) } ?? false
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
        var changed: [Activity] = []
        let date = entry.date

        if let open = current, date.timeIntervalSince(open.start) > options.maxActivityDuration {
            changed += finishCurrent(at: date, result: .abandoned)
        }

        switch entry.event {
        case .logVersion:
            break

        case let .zoneChange(instanceID, name, difficultyID):
            defer { zone = (instanceID, name, difficultyID) }
            guard let open = current, instanceID != zone?.instanceID else { break }
            switch open.kind {
            case .mythicPlus:
                // Leaving to the open world mid-key is normal (e.g. repairing); entering a
                // different instance is not.
                if difficultyID != 0, instanceID != keyInstanceID {
                    changed += finishCurrent(at: date, result: .abandoned)
                }
            default:
                changed += finishCurrent(at: date, result: .unknown)
            }

        case let .encounterStart(encounterID, name, difficultyID, _, _):
            if var key = current, key.kind == .mythicPlus {
                key.markers.append(Marker(date: date, kind: .bossPull, label: "Pull: \(name)"))
                current = key
                currentEncounterID = encounterID
                changed.append(key)
            } else {
                changed += finishCurrent(at: date, result: .unknown)
                let subtitle = [zone?.name, Difficulty.name(for: difficultyID)]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                let activity = Activity(
                    kind: Difficulty.activityKind(for: difficultyID),
                    title: name,
                    subtitle: subtitle,
                    start: date,
                    markers: [Marker(date: date, kind: .bossPull, label: "Pull: \(name)")]
                )
                current = activity
                currentEncounterID = encounterID
                changed.append(activity)
            }

        case let .encounterEnd(encounterID, name, _, _, success, _):
            guard var open = current else { break }
            let marker = Marker(date: date, kind: success ? .bossKill : .bossWipe,
                                label: success ? "Kill: \(name)" : "Wipe: \(name)")
            if open.kind == .mythicPlus {
                open.markers.append(marker)
                current = open
                currentEncounterID = nil
                changed.append(open)
            } else if currentEncounterID == encounterID {
                open.markers.append(marker)
                current = open
                changed += finishCurrent(at: date, result: success ? .kill : .wipe)
            }

        case let .challengeModeStart(zoneName, instanceID, _, keystoneLevel):
            changed += finishCurrent(at: date, result: .abandoned)
            current = Activity(kind: .mythicPlus, title: "\(zoneName) +\(keystoneLevel)",
                               subtitle: "Mythic+", start: date)
            keyInstanceID = instanceID
            changed.append(current!)

        case let .challengeModeEnd(_, success, _, durationMs):
            // WoW logs a stray CHALLENGE_MODE_END (all zeros) right before every key start.
            guard var key = current, key.kind == .mythicPlus else { break }
            if success, durationMs > 0 {
                key.subtitle = "Mythic+ · \(Self.formatDuration(Double(durationMs) / 1000))"
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

        case let .playerDied(_, name, isMine):
            let marker = Marker(date: date, kind: isMine ? .playerDeath : .death,
                                label: isMine ? "You died" : "\(Self.shortName(name)) died")
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
    /// An open encounter can't be resolved across files, but a key can: its end event will
    /// arrive in the new file.
    public mutating func logFileChanged(at date: Date) -> [Activity] {
        guard let open = current, open.kind != .mythicPlus else { return [] }
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
        current = nil
        currentEncounterID = nil
        keyInstanceID = nil
        arenaTeamID = nil
        return [open]
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
