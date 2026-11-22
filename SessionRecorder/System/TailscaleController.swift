import AppKit
import Observation
import RecorderCore
import os

/// Turns Tailscale off while WoW is running and back on a few seconds after it quits, when that's
/// on in Settings. Only undoes what it did: Tailscale that was already off stays off, and turning it
/// back on mid-game is left alone.
///
/// Wires `TailscaleCoordinator` to the game's state and Tailscale's CLI: polls Tailscale and runs
/// the commands the coordinator asks for. Decisions and bookkeeping live in the coordinator, where
/// they're tested.
@MainActor @Observable
final class TailscaleController {
    /// What the session lists, and the menu shows.
    static let gameName = "WoW"

    private(set) var coordinator: TailscaleCoordinator
    var session: TailscaleSession? { coordinator.session }
    private(set) var tailscale = TailscaleStatus(state: .unknown)
    /// The time `summary` is told. Moved on each second while a countdown or retry is showing.
    private(set) var now = Date()

    var isGameRunning = false {
        didSet { if isGameRunning != oldValue { evaluate() } }
    }

    @ObservationIgnored private let log = Logger(subsystem: "SessionRecorder", category: "Tailscale")
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let client = TailscaleClient()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var polling = false
    /// Bumped when a command starts, so a status read from before it is thrown away.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastPoll = Date.distantPast
    /// When the read behind `tailscale` started.
    @ObservationIgnored private var tailscaleAsOf = Date.distantPast
    @ObservationIgnored private var quitDone: (@MainActor () -> Void)?
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(settings: AppSettings) {
        self.settings = settings
        let store = JSONStore<TailscaleSession>(url: Self.sessionURL)
        let saved = store.load()
        let log = Logger(subsystem: "SessionRecorder", category: "Tailscale")
        coordinator = TailscaleCoordinator(session: saved) { session in
            do {
                if let session { try store.save(session) } else { try store.remove() }
            } catch {
                log.error("Couldn't save the Tailscale session: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        if let saved {
            log.info("Resuming a saved Tailscale session (\(saved.origin.rawValue, privacy: .public))")
        } else if let error = store.loadError {
            log.error("Couldn't read the Tailscale session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Where the promise to turn Tailscale back on is kept, so a crash or restart keeps it.
    private static var sessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "WoW Session Recorder", directoryHint: .isDirectory)
            .appending(path: "tailscale-session.json")
    }

    /// Call once WoW's state is known, so a saved session isn't wound down for a game that's open.
    func start(isGameRunning: Bool) {
        self.isGameRunning = isGameRunning
        started = true
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        })
        poll()
        evaluate()
    }

    /// Call when the setting changes.
    func settingChanged() {
        if settings.turnTailscaleOffWithWoW { poll() }
        evaluate()
    }

    var summary: TailscaleSummary? {
        TailscaleSummary.make(TailscaleSummary.Inputs(
            session: session, tailscale: tailscale.state, enabled: settings.turnTailscaleOffWithWoW,
            lastError: coordinator.lastError, now: now,
            time: { $0.formatted(date: .omitted, time: .shortened) }))
    }

    /// Whether there's anything to do: the setting is on, or a promise is still owed.
    private var isActive: Bool { settings.turnTailscaleOffWithWoW || session != nil }

    private var busy: Bool { coordinator.running != nil }

    /// Reads Tailscale's state. Results from before a command finished are dropped.
    func poll() {
        guard started, isActive, !polling, !busy, !coordinator.isQuitting else { return }
        polling = true
        let generation = generation, started = Date()
        Task {
            let status = await client.status()
            polling = false
            guard generation == self.generation, !busy, !coordinator.isQuitting else { return }
            lastPoll = Date()
            tailscaleAsOf = started
            if status != tailscale { tailscale = status }
            evaluate()
        }
    }

    // MARK: Deciding

    private func evaluate() {
        guard started else { return }
        defer { scheduleTick() }
        let date = Date()
        let inputs = TailscalePolicy.Inputs(
            open: isGameRunning ? [Self.gameName] : [], tailscale: tailscale.state, tailscaleAsOf: tailscaleAsOf,
            paused: !settings.turnTailscaleOffWithWoW, now: date)
        handle(coordinator.evaluate(inputs))
        // Only a countdown or a retry reads the time, so only those redraw each second.
        if session?.lastQuit != nil || coordinator.cooldown != nil { now = date }
        // A new session decides on a read from after it began.
        if !busy, TailscalePolicy.needsFreshStatus(session, inputs) { poll() }
    }

    private func handle(_ effect: TailscaleCoordinator.Effect?) {
        switch effect {
        case .run(let action): run(action)
        case .quit:
            let done = quitDone
            quitDone = nil
            // Never before the caller has returned.
            Task { done?() }
        case nil: break
        }
    }

    private func run(_ action: TailscaleAction) {
        generation += 1
        let started = Date()
        log.info("Turning Tailscale \(action == .turnOff ? "off" : "on", privacy: .public)")
        Task {
            let (error, outcome, status) = await client.perform(action)
            lastPoll = Date()
            tailscaleAsOf = started
            tailscale = status
            let next = coordinator.finished(action, outcome, error: error, now: Date())
            if coordinator.isQuitting { handle(next) } else { evaluate() }
        }
    }

    // MARK: Quitting

    /// How long until Tailscale is due back on after WoW quit, or nil if it isn't this app's to
    /// turn back on.
    var handBackDelay: TimeInterval? {
        guard let session, session.origin == .turnedOff, settings.turnTailscaleOffWithWoW else { return nil }
        guard let quit = session.lastQuit else { return TailscaleTiming.grace }
        return max(0, quit.addingTimeInterval(TailscaleTiming.grace).timeIntervalSinceNow)
    }

    /// Waits for a running command, then turns Tailscale back on if `handBack` and this app turned
    /// it off. An update relaunch passes false: the new copy carries on from the saved session. A
    /// failed hand-back stays saved, and the next launch tries again.
    func shutDown(handBack: Bool) async {
        guard coordinator.mustWaitBeforeQuitting(handBack: handBack) else {
            _ = coordinator.quit(handBack: handBack)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            quitDone = { continuation.resume() }
            handle(coordinator.quit(handBack: handBack))
        }
    }

    // MARK: Timer

    /// One-shot and rescheduled each time: every second while there's a countdown to show,
    /// otherwise every few seconds.
    private func scheduleTick() {
        let fast = session?.lastQuit != nil || coordinator.cooldown != nil
        let interval: TimeInterval = fast ? 1 : 5
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
            timer.resume()
            self.timer = timer
        }
        timer?.schedule(deadline: .now() + interval, leeway: .milliseconds(fast ? 100 : 1000))
    }

    private func tick() {
        let interval = session == nil ? TailscaleTiming.idlePollInterval : TailscaleTiming.sessionPollInterval
        if Date().timeIntervalSince(lastPoll) >= interval || (coordinator.cooldown.map { Date() >= $0.until } ?? false) {
            poll()
        }
        evaluate()
    }
}
