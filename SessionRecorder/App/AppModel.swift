import AppKit
import Observation
import RecorderCore
import ServiceManagement
import os

/// Owns recording, combat log tracking, and the activity library.
@MainActor
@Observable
final class AppModel {
    enum CaptureState: Equatable {
        case disabled
        case waitingForGame
        case gameNotVisible
        case standingBy
        case needsPermission
        case starting
        case recording(since: Date)
        case error(String)

        var isRecording: Bool {
            if case .recording = self { true } else { false }
        }

        var statusText: String {
            switch self {
            case .disabled: "Recording paused"
            case .waitingForGame: "Waiting for World of Warcraft"
            case .gameNotVisible: "Paused while WoW isn't on screen"
            case .standingBy: "Standing by until you enter an instance"
            case .needsPermission: "Needs Screen Recording permission"
            case .starting: "Starting…"
            case .recording: "Recording"
            case .error(let message): message
            }
        }
    }

    let settings = AppSettings()
    private(set) var captureState: CaptureState = .waitingForGame
    /// Newest first.
    private(set) var activities: [Activity] = []
    private(set) var segments: [Segment] = []
    private(set) var combatLogLastWrite: Date?
    private(set) var isClipping = false
    private(set) var retailFolder: URL?
    /// Timers, affix and spec names saved by the helper addon.
    private(set) var gameData = GameData()
    private var gameDataSource: (url: URL, modified: Date)?
    /// Set when the launch mode couldn't be applied (e.g. launchd refused the agent).
    private(set) var launchModeError: String?
    /// The library window is open; auto-quit waits until it closes.
    private var isLibraryOpen = false
    private var quitWhenLibraryCloses = false
    private var gameQuitTask: Task<Void, Never>?
    /// Instances-only mode keeps recording this long after you leave, so stepping out to
    /// repair or zoning in and out doesn't chop the footage up.
    private static let leaveGracePeriod: TimeInterval = 120
    private var graceUntil: Date?
    /// A standby bookmark records forward until this moment.
    private var recordUntil: Date?
    /// A new combat log file appeared and its first zone line hasn't arrived yet.
    ///
    /// WoW creates the file the instant logging starts but can hold the lines back for a
    /// minute or more. The helper addon only starts logging on entering an instance, so a new
    /// file means "probably just zoned in": record now, and let the zone line confirm it.
    private var awaitingZoneSince: Date?
    private static let awaitingZoneTimeout: TimeInterval = 10 * 60
    private var trackerWantedRecording = false
    private var lastWantsFootage: Bool?

    private let log = Logger(subsystem: "SessionRecorder", category: "App")
    private var library = Library()
    private var tracker = ActivityTracker()
    private let capture = CaptureEngine()
    private var tailer: CombatLogTailer?
    private var gameWatcher: GameWatcher?
    private let hotkeys = HotkeyManager()
    private var isGameRunning = false
    private var startTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var housekeeping: Timer?

    var segmentsDirectory: URL { settings.recordingsURL.appending(path: "Segments", directoryHint: .isDirectory) }
    private var libraryURL: URL { settings.recordingsURL.appending(path: "library.json") }

    // MARK: - Lifecycle

    func launch() {
        try? FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
        segments = SegmentIndex.scan(directory: segmentsDirectory)
        do {
            library = try Library.load(from: libraryURL)
        } catch {
            log.error("Couldn't load library: \(error.localizedDescription, privacy: .public)")
        }
        closeStaleActivities()
        refreshActivities()

        hotkeys.register(.bookmark) { [weak self] in self?.bookmark() }
        hotkeys.register(.clip) { [weak self] in self?.toggleClip() }

        refreshRetailFolder()
        refreshGameData()
        applyLaunchMode()
        if !settings.autoRecord { captureState = .disabled }
        capture.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in self?.captureStoppedUnexpectedly(error) }
        }
        gameWatcher = GameWatcher { [weak self] running in self?.gameRunningChanged(running) }
        gameWatcher?.start()

        housekeeping = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkCaptureTarget()
                self?.evaluateRecording()
                self?.refreshGameData()
            }
        }
        runRetention()
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runRetention() }
        }
    }

    func shutdown() async {
        startTask?.cancel()
        apply(tracker.endAll(at: Date()))
        await capture.stop()
        saveNow()
    }

    // MARK: - Recording

    func setAutoRecord(_ enabled: Bool) {
        settings.autoRecord = enabled
        if enabled {
            captureState = isGameRunning ? .starting : .waitingForGame
            scheduleCaptureStart(after: 0)
        } else {
            startTask?.cancel()
            captureState = .disabled
            Task { await capture.stop() }
        }
    }

    /// Restarts capture so new quality settings take effect.
    func restartCapture() {
        guard capture.isRunning else { return }
        Task {
            await capture.stop()
            scheduleCaptureStart(after: 0)
        }
    }

    private func gameRunningChanged(_ running: Bool) {
        guard running != isGameRunning else { return }
        isGameRunning = running
        if running {
            gameQuitTask?.cancel()
            quitWhenLibraryCloses = false
            refreshRetailFolder()
            tailer?.start()
            lastWantsFootage = nil
            CompanionApps.open(settings.companionAppURLs)
            // Give WoW a moment to create its window.
            scheduleCaptureStart(after: 3)
        } else {
            startTask?.cancel()
            tailer?.stop()
            apply(tracker.endAll(at: Date()))
            if settings.autoRecord { captureState = .waitingForGame }
            gameQuitTask = Task { await gameDidQuit() }
        }
    }

    /// Seconds companion apps get after WoW quits, in case they sync game data on exit.
    private static let companionQuitDelay: TimeInterval = 30

    private func gameDidQuit() async {
        await capture.stop()
        saveNow()
        let companions = settings.companionAppURLs
        if settings.quitCompanionsWithWoW, !companions.isEmpty {
            try? await Task.sleep(for: .seconds(Self.companionQuitDelay))
            // Cancelled when WoW relaunches (e.g. a quick restart).
            guard !Task.isCancelled, !isGameRunning else { return }
            CompanionApps.quit(companions)
        }
        guard !Task.isCancelled, !isGameRunning, settings.launchMode == .withWoW else { return }
        if isLibraryOpen {
            quitWhenLibraryCloses = true
        } else {
            NSApp.terminate(nil)
        }
    }

    func libraryVisibilityChanged(_ isOpen: Bool) {
        isLibraryOpen = isOpen
        if !isOpen, quitWhenLibraryCloses, !isGameRunning {
            NSApp.terminate(nil)
        }
    }

    private func scheduleCaptureStart(after delay: TimeInterval) {
        startTask?.cancel()
        startTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await startCapture()
        }
    }

    private func startCapture() async {
        guard settings.autoRecord, isGameRunning, !capture.isRunning else { return }
        guard wantsFootage(now: Date()) else {
            captureState = .standingBy
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            captureState = .needsPermission
            scheduleCaptureStart(after: 5)
            return
        }
        captureState = .starting
        do {
            try await capture.start(
                bundleID: WoWInstall.bundleID,
                quality: settings.quality,
                fps: settings.fps,
                captureAudio: settings.captureAudio,
                directory: segmentsDirectory,
                onSegment: { [weak self] segment in
                    Task { @MainActor in self?.segmentFinished(segment) }
                })
            captureState = .recording(since: Date())
        } catch CaptureError.noGameWindow {
            captureState = .gameNotVisible
            scheduleCaptureStart(after: 3)
        } catch CaptureError.gameNotRunning {
            captureState = .waitingForGame
            scheduleCaptureStart(after: 5)
        } catch {
            log.error("Capture failed to start: \(error.localizedDescription, privacy: .public)")
            captureState = .error(error.localizedDescription)
            scheduleCaptureStart(after: 10)
        }
    }

    private func captureStoppedUnexpectedly(_ error: Error) {
        guard settings.autoRecord else { return }
        captureState = isGameRunning ? .error(error.localizedDescription) : .waitingForGame
        if isGameRunning { scheduleCaptureStart(after: 3) }
    }

    /// Restarts capture when the game window moves or toggles fullscreen, so the crop stays right.
    private func checkCaptureTarget() {
        guard capture.isRunning, let target = capture.target,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: WoWInstall.bundleID).first?.processIdentifier,
              let now = CaptureEngine.currentTarget(processID: pid)
        else { return }
        if !now.matches(target) {
            log.info("Game window changed; restarting capture")
            Task {
                await capture.stop()
                scheduleCaptureStart(after: 0)
            }
        }
    }

    // MARK: - Instances-only recording

    func setRecordingScope(_ scope: RecordingScope) {
        settings.recordingScope = scope
        lastWantsFootage = nil
        evaluateRecording()
    }

    var helperAddonStatus: HelperAddon.Status {
        retailFolder.map(HelperAddon.status(retail:)) ?? .notInstalled
    }

    /// Instances-only mode needs the combat log to know where you are. Without a working
    /// helper addon or a recently active log, it falls back to recording everything.
    var canDetectInstances: Bool {
        switch helperAddonStatus {
        case .active, .notLoadedYet: return true
        case .disabled, .notInstalled: break
        }
        if let last = combatLogLastWrite, Date().timeIntervalSince(last) < 300 { return true }
        return false
    }

    /// Why instances-only mode is recording everything, for the menu and settings.
    var fallbackReason: String {
        helperAddonStatus == .disabled
            ? "The helper addon is turned off in WoW's addon list"
            : "Combat logging isn't on"
    }

    /// Inside an instance the log is written almost constantly. If it's been silent this long,
    /// assume you've left even if the zone line never arrived.
    private static let quietLogTimeout: TimeInterval = 5 * 60

    /// Footage is needed because of where you are or what's in progress.
    private func trackerNeedsFootage(now: Date) -> Bool {
        if tracker.current != nil || tracker.manualClip != nil { return true }
        guard tracker.isInInstance else { return false }
        guard let last = combatLogLastWrite else { return true }
        return now.timeIntervalSince(last) < Self.quietLogTimeout
    }

    var isRecordingEverythingAsFallback: Bool {
        settings.recordingScope == .instancesOnly && !canDetectInstances
    }

    private func wantsFootage(now: Date) -> Bool {
        guard settings.recordingScope == .instancesOnly, canDetectInstances else { return true }
        if trackerNeedsFootage(now: now) { return true }
        if let awaitingZoneSince, now.timeIntervalSince(awaitingZoneSince) < Self.awaitingZoneTimeout { return true }
        if let recordUntil, recordUntil > now { return true }
        if let graceUntil, graceUntil > now { return true }
        return false
    }

    /// Starts or stops capture when the need for footage changes.
    private func evaluateRecording() {
        let now = Date()
        let trackerWants = trackerNeedsFootage(now: now)
        if trackerWantedRecording, !trackerWants {
            graceUntil = now.addingTimeInterval(Self.leaveGracePeriod)
        }
        trackerWantedRecording = trackerWants

        guard settings.autoRecord, isGameRunning else { return }
        let wanted = wantsFootage(now: now)
        guard wanted != lastWantsFootage else { return }
        lastWantsFootage = wanted
        if wanted {
            if !capture.isRunning { scheduleCaptureStart(after: 0) }
        } else {
            log.info("Left instance; standing by")
            startTask?.cancel()
            captureState = .standingBy
            Task { await capture.stop() }
        }
    }

    private func segmentFinished(_ segment: Segment) {
        segments.append(segment)
    }

    // MARK: - Combat log

    /// Re-reads the helper addon's SavedVariables when WoW has rewritten them (on logout/reload).
    func refreshGameData() {
        guard let retailFolder, let url = HelperAddon.savedVariablesURL(retail: retailFolder),
              let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              gameDataSource?.url != url || gameDataSource?.modified != modified,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        gameDataSource = (url, modified)
        if let db = LuaSavedVariables.parse(text)["SessionRecorderHelperDB"] {
            gameData = GameData(savedVariables: db)
            tracker.options.cooldownSpellIDs = Set(gameData.cooldowns.keys)
        }
    }

    func refreshRetailFolder() {
        let folder = settings.wowRetailPath.flatMap { WoWInstall.normalize(URL(fileURLWithPath: $0)) }
            ?? WoWInstall.detectRetailFolder()
        guard folder != retailFolder || tailer == nil else { return }
        retailFolder = folder
        tailer?.stop()
        tailer = nil
        if settings.launchMode == .withWoW { applyLaunchMode() }
        guard let folder else { return }
        let tailer = CombatLogTailer(
            logsDirectory: WoWInstall.logsFolder(in: folder),
            onEntries: { [weak self] entries in
                Task { @MainActor in self?.handle(entries) }
            },
            onNewFile: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.awaitingZoneSince = Date()
                    self.apply(self.tracker.logFileChanged(at: Date()))
                    self.evaluateRecording()
                }
            },
            onWrite: { [weak self] date in
                Task { @MainActor in self?.combatLogLastWrite = date }
            },
            onSeedZone: { [weak self] entry in
                Task { @MainActor in
                    // The log was written within the last few minutes, or it wouldn't be seeded.
                    self?.combatLogLastWrite = self?.combatLogLastWrite ?? Date()
                    self?.tracker.seedZone(from: entry)
                    self?.evaluateRecording()
                }
            })
        // Only poll the log while WoW is running; nothing gets written otherwise.
        if isGameRunning { tailer.start() }
        self.tailer = tailer
    }

    private func handle(_ entries: [CombatLogEntry]) {
        for entry in entries {
            if case .zoneChange = entry.event { awaitingZoneSince = nil }
            apply(tracker.handle(entry))
        }
        evaluateRecording()
    }

    // MARK: - Hotkey actions

    func bookmark() {
        let now = Date()
        let isRecording = capture.isRunning
        apply(tracker.bookmark(at: now, hasFootageBefore: isRecording))
        if !isRecording, settings.autoRecord, isGameRunning {
            // Standing by: there's nothing before this moment, so record forward instead.
            recordUntil = now.addingTimeInterval(tracker.options.forwardClipLength)
            evaluateRecording()
        }
        NSSound(named: isRecording ? "Tink" : "Glass")?.play()
    }

    func toggleClip() {
        apply(tracker.toggleManualClip(at: Date()))
        isClipping = tracker.manualClip != nil
        NSSound(named: isClipping ? "Morse" : "Pop")?.play()
        evaluateRecording()
    }

    // MARK: - Library

    func toggleFavorite(_ activity: Activity) {
        guard let index = library.activities.firstIndex(where: { $0.id == activity.id }) else { return }
        library.activities[index].isFavorite.toggle()
        refreshActivities()
        scheduleSave()
    }

    /// Removes the activity. Its footage is cleaned up by retention once nothing else needs it.
    func delete(_ activity: Activity) {
        library.activities.removeAll { $0.id == activity.id }
        refreshActivities()
        scheduleSave()
    }

    func setNotes(_ notes: String, for id: Activity.ID) {
        guard let index = library.activities.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        library.activities[index].notes = trimmed.isEmpty ? nil : notes
        refreshActivities()
        scheduleSave()
    }

    /// Keeps part of a recording as its own clip, so its footage outlives the rest.
    @discardableResult
    func saveClip(of item: PlaybackItem, from start: Date, to end: Date) -> Activity {
        let clip: Activity
        if let id = item.activityID, let activity = library.activities.first(where: { $0.id == id }) {
            clip = activity.clip(from: start, to: end)
        } else {
            clip = Activity(kind: .clip, title: "\(item.title) (clip)", start: start, end: end, result: .unknown,
                            markers: item.markers.filter { $0.date >= start && $0.date <= end })
        }
        apply([clip])
        return clip
    }

    enum DeathRecapError: LocalizedError {
        case noLogsFolder
        case logMissing
        case nothingLogged

        var errorDescription: String? {
            switch self {
            case .noLogsFolder: "Set your WoW install in Settings to read death recaps from the combat log."
            case .logMissing: "The combat log for this death is no longer in WoW's Logs folder."
            case .nothingLogged: "The combat log has nothing about this death."
            }
        }
    }

    /// What led up to a death, read back from the combat log.
    func deathRecap(for marker: Marker) async throws -> DeathRecap {
        guard let guid = marker.unitGUID else { throw DeathRecapError.nothingLogged }
        guard let retailFolder else { throw DeathRecapError.noLogsFolder }
        let logs = WoWInstall.logsFolder(in: retailFolder)
        // Newer death markers know their exact line; older ones are found by their time.
        let hinted = marker.log.map { logs.appending(path: $0.fileName) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard let url = hinted ?? CombatLogFiles.file(at: marker.date, in: logs) else { throw DeathRecapError.logMissing }
        let anchor = hinted != nil ? marker.log?.offset : nil
        let from = marker.date.addingTimeInterval(-DeathRecap.window)
        let to = marker.date.addingTimeInterval(1)
        let recap = try await Task.detached(priority: .userInitiated) {
            DeathRecap.build(lines: try CombatLogFiles.lines(in: url, anchor: anchor, from: from, to: to),
                             unitGUID: guid, death: marker.date)
        }.value
        guard !recap.events.isEmpty else { throw DeathRecapError.nothingLogged }
        return recap
    }

    func segments(from start: Date, to end: Date) -> [Segment] {
        SegmentIndex.overlapping(segments, start: start, end: end)
    }

    var sessions: [FootageSession] {
        SegmentIndex.sessions(segments).reversed()
    }

    var storageBytes: Int64 {
        segments.reduce(0) { total, segment in
            total + Int64((try? segment.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func runRetention() {
        let now = Date()
        let policy = settings.retention
        let expired = Set(policy.expiredActivities(library.activities, now: now).map(\.id))
        if !expired.isEmpty {
            library.activities.removeAll { expired.contains($0.id) }
            refreshActivities()
            scheduleSave()
        }
        let doomed = policy.segmentsToDelete(segments, keeping: library.activities, now: now)
        for segment in doomed {
            try? FileManager.default.removeItem(at: segment.url)
        }
        if !doomed.isEmpty {
            let removed = Set(doomed.map(\.url))
            segments.removeAll { removed.contains($0.url) }
            log.info("Retention removed \(doomed.count) segments and \(expired.count) activities")
        }
    }

    // MARK: - Settings helpers

    func setLaunchMode(_ mode: LaunchMode) {
        settings.launchMode = mode
        applyLaunchMode()
    }

    /// Makes the login item and the Open-with-WoW agent match the chosen launch mode.
    private func applyLaunchMode() {
        launchModeError = nil
        do {
            switch settings.launchMode {
            case .atLogin:
                WoWLaunchAgent.uninstall()
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            case .withWoW:
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                guard let retailFolder else {
                    launchModeError = "Set your WoW install below so the app knows when WoW starts."
                    return
                }
                try WoWLaunchAgent.install(appURL: Bundle.main.bundleURL, retail: retailFolder)
            case .manual:
                WoWLaunchAgent.uninstall()
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            launchModeError = error.localizedDescription
            log.error("Launch mode: \(error.localizedDescription, privacy: .public)")
        }
    }

    func addCompanionApp(_ url: URL) {
        guard !settings.companionAppPaths.contains(url.path) else { return }
        settings.companionAppPaths.append(url.path)
        if isGameRunning { CompanionApps.open([url]) }
    }

    func removeCompanionApp(_ url: URL) {
        settings.companionAppPaths.removeAll { $0 == url.path }
    }

    func moveRecordings(to url: URL) {
        settings.recordingsPath = url.path
        try? FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
        segments = SegmentIndex.scan(directory: segmentsDirectory)
        library = (try? Library.load(from: libraryURL)) ?? Library()
        refreshActivities()
        restartCapture()
    }

    // MARK: - Private

    private func apply(_ changed: [Activity]) {
        guard !changed.isEmpty else { return }
        library.upsert(changed)
        refreshActivities()
        scheduleSave()
    }

    private func refreshActivities() {
        activities = library.activities.sorted { $0.start > $1.start }
    }

    /// Activities left open by a crash or force-quit end where their footage ends.
    private func closeStaleActivities() {
        for index in library.activities.indices where library.activities[index].end == nil {
            let activity = library.activities[index]
            let lastFootage = segments.last { $0.end > activity.start }?.end
            library.activities[index].end = max(lastFootage ?? activity.start, activity.start)
            library.activities[index].result = .abandoned
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        do {
            try library.save(to: libraryURL)
        } catch {
            log.error("Couldn't save library: \(error.localizedDescription, privacy: .public)")
        }
    }
}
