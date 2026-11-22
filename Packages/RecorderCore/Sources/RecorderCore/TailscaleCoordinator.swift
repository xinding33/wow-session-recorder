import Foundation

/// Everything the app remembers between events, and the bookkeeping around `TailscalePolicy`: saving the
/// session before acting, one command at a time, errors and retry cooldowns, and quitting. The
/// app feeds it events and runs the effects it returns, so every sequence here is testable.
public struct TailscaleCoordinator {
    public struct Cooldown: Equatable, Sendable {
        /// The command that failed. Only it waits; the opposite command can still run.
        public var action: TailscaleAction
        public var until: Date
    }

    public enum Effect: Equatable, Sendable {
        /// Run this command, then call `finished`.
        case run(TailscaleAction)
        /// Quitting can go ahead.
        case quit
    }

    public private(set) var session: TailscaleSession?
    /// Why the last command failed, until it stops mattering.
    public private(set) var lastError: String?
    public private(set) var cooldown: Cooldown?
    /// The command running now, if any.
    public private(set) var running: TailscaleAction?
    public private(set) var isQuitting = false

    private var handBackOnQuit = true
    private var handingBack = false
    /// False after a failed write, so the next change of anything retries it.
    private var diskIsCurrent = true
    private let persist: (TailscaleSession?) throws -> Void

    /// `persist` writes the session to disk, or removes it for nil.
    public init(session: TailscaleSession?, persist: @escaping (TailscaleSession?) throws -> Void) {
        self.session = session
        self.persist = persist
    }

    // MARK: Deciding

    /// Steps the policy. `inputs.blocked` is filled in from the cooldown.
    public mutating func evaluate(_ inputs: TailscalePolicy.Inputs) -> Effect? {
        guard running == nil, !isQuitting else { return nil }
        if let cooldown, inputs.now >= cooldown.until { self.cooldown = nil }
        var inputs = inputs
        inputs.blocked = cooldown?.action
        let step = TailscalePolicy.step(session, inputs)
        let saved = save(step.session)
        // With a watched app open and no pause, keeping Tailscale off is right, so a failed
        // hand-back no longer matters.
        defer { settle(inputs.tailscale, handBackDue: inputs.open.isEmpty || inputs.paused) }
        guard let action = step.action else { return nil }
        if action == .turnOff && !saved {
            // The promise to turn Tailscale back on couldn't be written down, so don't turn it off.
            session = TailscalePolicy.finished(.turnOff, .skipped(.on), session: session)
            fail(.turnOff, "WoW Session Recorder couldn't save its state.", now: inputs.now)
            return nil
        }
        // Turning Tailscale back on is always safe, saved or not.
        running = action
        return .run(action)
    }

    /// Records a command's result. While quitting, says what to do next.
    public mutating func finished(_ action: TailscaleAction, _ outcome: TailscaleOutcome, error: String?, now: Date) -> Effect? {
        running = nil
        _ = save(TailscalePolicy.finished(action, outcome, session: session))
        if let error {
            fail(action, error, now: now)
        } else {
            lastError = nil
            cooldown = nil
        }
        switch outcome {
        case .skipped(let state), .ran(_, let state): settle(state)
        }
        guard isQuitting else { return nil }
        if handingBack { return .quit }
        return afterRunning()
    }

    // MARK: Quitting

    /// Whether quitting has to wait: a command is running, or (when handing back) Tailscale is
    /// the app's to turn back on.
    public func mustWaitBeforeQuitting(handBack: Bool) -> Bool {
        running != nil || (handBack && session?.origin == .turnedOff)
    }

    /// Stops deciding. Waits for a running command, so its result is saved, then hands Tailscale
    /// back if `handBack` and the app turned it off. An update relaunch passes false: the new copy
    /// carries on from the saved session. Returns nil while a command is still running; its
    /// `finished` returns the next effect.
    public mutating func quit(handBack: Bool) -> Effect? {
        isQuitting = true
        handBackOnQuit = handBack
        return running == nil ? afterRunning() : nil
    }

    private mutating func afterRunning() -> Effect {
        guard handBackOnQuit, session?.origin == .turnedOff else { return .quit }
        handingBack = true
        running = .turnOn
        return .run(.turnOn)
    }

    // MARK: Bookkeeping

    /// Updates the session in memory and on disk. False if the disk couldn't be updated.
    private mutating func save(_ new: TailscaleSession?) -> Bool {
        guard new != session || !diskIsCurrent else { return true }
        session = new
        do {
            try persist(new)
            diskIsCurrent = true
        } catch {
            diskIsCurrent = false
        }
        return diskIsCurrent
    }

    private mutating func fail(_ action: TailscaleAction, _ error: String, now: Date) {
        lastError = error
        cooldown = Cooldown(action: action, until: now.addingTimeInterval(TailscaleTiming.retryInterval))
    }

    /// Drops an error once what the failed command was for no longer needs doing.
    private mutating func settle(_ tailscale: TailscaleState, handBackDue: Bool = true) {
        guard let failed = cooldown?.action ?? (lastError != nil ? .turnOff : nil) else { return }
        let resolved = switch (failed, session?.origin) {
        case (_, nil), (_, .alreadyOff?), (_, .userTurnedOn?): true
        case (.turnOff, .turnedOff?): tailscale == .off
        case (.turnOff, .waiting?): false
        case (.turnOn, .turnedOff?): tailscale == .on || !handBackDue
        case (.turnOn, .waiting?): true
        }
        if resolved {
            lastError = nil
            cooldown = nil
        }
    }
}
