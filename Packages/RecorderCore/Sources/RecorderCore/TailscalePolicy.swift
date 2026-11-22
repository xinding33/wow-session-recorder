import Foundation

/// A stretch of time during which at least one watched app is open, plus the grace period after the
/// last one quits. Saved to disk before the app turns Tailscale off, so a crash or restart can undo it.
public struct TailscaleSession: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// Tailscale's state isn't known yet, so nothing has been decided.
        case waiting
        /// The app turned Tailscale off and turns it back on when the session ends.
        case turnedOff
        /// Tailscale was already off, so the app leaves it off.
        case alreadyOff
        /// The app turned Tailscale off, then the user turned it back on, so it's left alone.
        case userTurnedOn
    }

    public var origin: Origin
    public var started: Date
    /// The watched apps open most recently, for the menu.
    public var apps: [String]
    /// When the last watched app quit. Reopening one clears it.
    public var lastQuit: Date?

    public init(origin: Origin, started: Date, apps: [String], lastQuit: Date? = nil) {
        self.origin = origin
        self.started = started
        self.apps = apps
        self.lastQuit = lastQuit
    }
}

public enum TailscaleAction: Equatable, Sendable {
    case turnOff, turnOn
}

/// What happened when the app went to run a command. The client reads Tailscale's state right
/// before running it, on the same queue, so a decision made on an older read can't override
/// what the user just did.
public enum TailscaleOutcome: Equatable, Sendable {
    /// Tailscale wasn't in the state the command changes, so it didn't run. Carries that state.
    case skipped(TailscaleState)
    /// The command ran, and whether the CLI reported success. Carries the state read back afterwards.
    case ran(succeeded: Bool, readBack: TailscaleState)
}

/// Decides what to do with Tailscale. Pure, so every rule is tested without touching Tailscale.
public enum TailscalePolicy {
    public struct Inputs: Sendable {
        /// Watched apps that are open.
        public var open: [String]
        public var tailscale: TailscaleState
        /// When the read that produced `tailscale` started. A new session decides only on a read
        /// from after it began: an older "on" may predate the user turning Tailscale off.
        public var tailscaleAsOf: Date
        /// Turned off in Settings. Hands Tailscale back at once and then leaves it alone.
        public var paused: Bool
        public var grace: TimeInterval
        /// A command that failed and waits for its retry. The opposite command isn't held up.
        public var blocked: TailscaleAction?
        public var now: Date

        public init(open: [String], tailscale: TailscaleState, tailscaleAsOf: Date? = nil, paused: Bool = false,
                    grace: TimeInterval = TailscaleTiming.grace,
                    blocked: TailscaleAction? = nil, now: Date) {
            self.open = open
            self.tailscale = tailscale
            self.tailscaleAsOf = tailscaleAsOf ?? now
            self.paused = paused
            self.grace = grace
            self.blocked = blocked
            self.now = now
        }
    }

    public struct Step: Equatable, Sendable {
        /// Save this before running `action`.
        public var session: TailscaleSession?
        public var action: TailscaleAction?

        public init(session: TailscaleSession?, action: TailscaleAction? = nil) {
            self.session = session
            self.action = action
        }
    }

    /// The next session and the command to run, if any. Call it whenever an input changes, and
    /// never while a command is running: the state it reads would be out of date.
    public static func step(_ session: TailscaleSession?, _ inputs: Inputs) -> Step {
        let active = !inputs.open.isEmpty && !inputs.paused
        guard var session else {
            guard active else { return Step(session: nil) }
            return decide(TailscaleSession(origin: .waiting, started: inputs.now, apps: inputs.open), inputs)
        }

        if active {
            session.apps = inputs.open
            session.lastQuit = nil
            return decide(session, inputs)
        }

        guard session.origin == .turnedOff else {
            // Nothing to undo. Hold the session through the grace period, so a quick relaunch
            // doesn't turn off Tailscale the user turned on.
            if inputs.paused || session.origin == .waiting { return Step(session: nil) }
            let quit = session.lastQuit ?? inputs.now
            session.lastQuit = quit
            return Step(session: inputs.now >= quit + inputs.grace ? nil : session)
        }

        switch inputs.tailscale {
        case .on:
            // Someone turned it back on already.
            return Step(session: nil)
        case .off:
            let quit = session.lastQuit ?? inputs.now
            session.lastQuit = quit
            // Pausing hands Tailscale back straight away.
            let due = inputs.paused || inputs.now >= quit + inputs.grace
            return Step(session: session, action: due && inputs.blocked != .turnOn ? .turnOn : nil)
        case .unknown, .needsLogin, .notInstalled, .unreachable:
            // Keep the promise until Tailscale can be reached again.
            if session.lastQuit == nil { session.lastQuit = inputs.now }
            return Step(session: session)
        }
    }

    /// Whether a session waiting to decide needs a newer read of Tailscale first.
    public static func needsFreshStatus(_ session: TailscaleSession?, _ inputs: Inputs) -> Bool {
        session?.origin == .waiting && inputs.tailscaleAsOf < session!.started
    }

    /// A session with a watched app open.
    private static func decide(_ session: TailscaleSession, _ inputs: Inputs) -> Step {
        var session = session
        let fresh = inputs.tailscaleAsOf >= session.started
        switch (session.origin, inputs.tailscale) {
        case (.waiting, .on) where fresh:
            guard inputs.blocked != .turnOff else { return Step(session: session) }
            session.origin = .turnedOff
            return Step(session: session, action: .turnOff)
        case (.waiting, .off) where fresh:
            session.origin = .alreadyOff
        case (.turnedOff, .on):
            session.origin = .userTurnedOn
        default:
            break
        }
        return Step(session: session)
    }

    /// The session after a command finished.
    public static func finished(_ action: TailscaleAction, _ outcome: TailscaleOutcome, session: TailscaleSession?) -> TailscaleSession? {
        switch outcome {
        case .ran(let succeeded, let readBack):
            if action == .turnOff, succeeded, readBack == .on {
                // `down` worked and Tailscale is on again: the user turned it back on.
                guard var session else { return nil }
                session.origin = .userTurnedOn
                return session
            }
            return finished(action, readBack: readBack, session: session)
        case .skipped(let state):
            switch (action, state) {
            case (.turnOff, .off):
                // The user turned it off first. Not the app's to turn back on.
                guard var session else { return nil }
                session.origin = .alreadyOff
                return session
            case (.turnOff, _):
                guard var session else { return nil }
                session.origin = .waiting
                return session
            case (.turnOn, .on):
                // Someone turned it back on already.
                return nil
            case (.turnOn, _):
                return session
            }
        }
    }

    /// The session after a command ran, given Tailscale's state read back afterwards.
    static func finished(_ action: TailscaleAction, readBack: TailscaleState, session: TailscaleSession?) -> TailscaleSession? {
        switch (action, readBack) {
        case (.turnOff, .on):
            // Definitely still on, so there's nothing of the app's to undo. Retry from scratch.
            guard var session else { return nil }
            session.origin = .waiting
            return session
        case (.turnOff, _):
            // Off, or unknown because the read failed. `down` may have worked, so keep the
            // promise to turn it back on.
            return session
        case (.turnOn, .on):
            return nil
        case (.turnOn, _):
            return session
        }
    }
}
