import Foundation

/// What the menu and Settings say about Tailscale.
public struct TailscaleSummary: Equatable, Sendable {
    public enum Fix: Equatable, Sendable {
        case openTailscale, getTailscale
    }

    public var title: String
    public var detail: String
    /// The app can't control Tailscale, or a command failed.
    public var isProblem: Bool
    public var fix: Fix?

    public init(title: String, detail: String, isProblem: Bool = false, fix: Fix? = nil) {
        self.title = title
        self.detail = detail
        self.isProblem = isProblem
        self.fix = fix
    }

    public struct Inputs: Sendable {
        public var session: TailscaleSession?
        public var tailscale: TailscaleState
        /// Whether turning Tailscale off while WoW runs is on in Settings.
        public var enabled: Bool
        /// The last command's error, until a command succeeds.
        public var lastError: String?
        public var now: Date
        /// Formats a time of day, e.g. "2:31 PM".
        public var time: @Sendable (Date) -> String

        public init(session: TailscaleSession?, tailscale: TailscaleState, enabled: Bool, lastError: String? = nil,
                    now: Date, time: @escaping @Sendable (Date) -> String) {
            self.session = session
            self.tailscale = tailscale
            self.enabled = enabled
            self.lastError = lastError
            self.now = now
            self.time = time
        }
    }

    /// Nil when the feature is off and there's nothing to hand back.
    public static func make(_ inputs: Inputs) -> TailscaleSummary? {
        guard inputs.enabled else {
            // Turning the setting off hands Tailscale back. Until that has worked, say so.
            guard inputs.session?.origin == .turnedOff else { return nil }
            return problem(inputs) ?? TailscaleSummary(title: "Turning Tailscale back on…",
                                                       detail: "Then it's left alone.")
        }

        if let problem = problem(inputs) { return problem }

        guard let session = inputs.session else {
            let title = switch inputs.tailscale {
            case .on: "Tailscale is on"
            case .off: "Tailscale is off"
            default: "Checking Tailscale…"
            }
            return TailscaleSummary(title: title, detail: "It's turned off while WoW is running.")
        }

        let names = list(session.apps)
        let quits = session.apps.count == 1 ? "quits" : "quit"
        switch session.origin {
        case .waiting:
            return TailscaleSummary(title: "Checking Tailscale…", detail: "\(names) is open.")
        case .turnedOff:
            let grace = Int(TailscaleTiming.grace)
            if let quit = session.lastQuit {
                let remaining = Int((quit.timeIntervalSince(inputs.now) + TailscaleTiming.grace).rounded(.up))
                let title = remaining > 0 ? "Turning Tailscale on in \(remaining) s" : "Turning Tailscale on…"
                let reopen = session.apps.count == 1 ? "Reopening it cancels this." : "Reopening one cancels this."
                return TailscaleSummary(title: title, detail: "\(names) quit. \(reopen)")
            }
            let after = session.apps.count == 1 ? "it quits" : "they quit"
            return TailscaleSummary(title: "Tailscale is off while \(names) runs",
                                    detail: "Since \(inputs.time(session.started)). Turns back on \(grace) s after \(after).")
        case .alreadyOff:
            return TailscaleSummary(title: "Tailscale was already off",
                                    detail: "It stays off after \(names) \(quits).")
        case .userTurnedOn:
            return TailscaleSummary(title: "You turned Tailscale back on",
                                    detail: "It's left alone until \(names) \(quits).")
        }
    }

    private static func problem(_ inputs: Inputs) -> TailscaleSummary? {
        let retry = "Retries every \(Int(TailscaleTiming.retryInterval)) s."
        switch inputs.tailscale {
        case .notInstalled:
            return TailscaleSummary(title: "Tailscale isn't installed",
                                    detail: "This works with the standalone Tailscale app from tailscale.com.",
                                    isProblem: true, fix: .getTailscale)
        case .needsLogin:
            return TailscaleSummary(title: "Tailscale is logged out", detail: "Log in to Tailscale and it's picked up.",
                                    isProblem: true, fix: .openTailscale)
        case .unreachable(let detail):
            return TailscaleSummary(title: "Can't reach Tailscale", detail: "\(detail) \(retry)", isProblem: true,
                                    fix: .openTailscale)
        case .unknown, .on, .off:
            break
        }
        if let error = inputs.lastError {
            let title = inputs.session?.origin == .turnedOff ? "Couldn't turn Tailscale on" : "Couldn't turn Tailscale off"
            return TailscaleSummary(title: title, detail: "\(error) \(retry)", isProblem: true)
        }
        return nil
    }

    /// "A", "A and B", "A, B and C". More than three become "4 apps".
    public static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: "no apps"
        case 1: names[0]
        case 2, 3: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: "\(names.count) apps"
        }
    }
}

/// Timing shared by the app and the text it shows.
public enum TailscaleTiming {
    /// How long after WoW quits Tailscale goes back on, so a quick relaunch doesn't make it flap.
    public static let grace: TimeInterval = 10
    /// How long after a failed command the app tries again.
    public static let retryInterval: TimeInterval = 30
    /// How often Tailscale's state is checked while a session is open, to notice it being turned on by hand.
    public static let sessionPollInterval: TimeInterval = 5
    /// How often it's checked otherwise, for the menu and Settings.
    public static let idlePollInterval: TimeInterval = 30
}
