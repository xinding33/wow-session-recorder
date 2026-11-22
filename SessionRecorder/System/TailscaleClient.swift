import AppKit
import RecorderCore
import os

/// Runs the standalone Tailscale app's CLI, one command at a time and never on the main thread.
///
/// Turning Tailscale on is a bare `tailscale up`: with no flags, the CLI only sets WantRunning and
/// keeps every other setting (exit node, routes, DNS). Any flag, even `--timeout`, would make it
/// compare all settings and refuse unless every non-default one is repeated.
final class TailscaleClient: Sendable {
    private static let log = Logger(subsystem: "SessionRecorder", category: "Tailscale")
    private let queue = DispatchQueue(label: "io.github.xinding33.wow-session-recorder.tailscale")

    /// The standalone app, if it's installed.
    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: TailscaleApp.bundleID)
    }

    func status() async -> TailscaleStatus {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.statusNow()) }
        }
    }

    /// Runs the command, then reads the state back, because that is what counts.
    func perform(_ action: TailscaleAction) async -> (error: String?, outcome: TailscaleOutcome, status: TailscaleStatus) {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.performNow(action)) }
        }
    }

    /// Blocks. Only for the queue.
    private static func statusNow() -> TailscaleStatus {
        guard let app = appURL else { return TailscaleStatus(state: .notInstalled) }
        let result = run(TailscaleApp.cli(inApp: app), ["status", "--json"], timeout: 10)
        if result.timedOut { return TailscaleStatus(state: .unreachable("Tailscale didn't answer.")) }
        return TailscaleStatus.parse(output: result.output, exitStatus: result.exitStatus, errorOutput: result.errorOutput)
    }

    private static func performNow(_ action: TailscaleAction) -> (error: String?, outcome: TailscaleOutcome, status: TailscaleStatus) {
        // Read first, here on the queue, so the decision rests on the state right now.
        let before = statusNow()
        let from: TailscaleState = action == .turnOff ? .on : .off
        guard before.state == from, let app = appURL else {
            log.info("Skipped tailscale \(action == .turnOff ? "down" : "up", privacy: .public): it was already \(before.state == .off ? "off" : before.state == .on ? "on" : "unavailable", privacy: .public)")
            let settled = before.state == (action == .turnOff ? .off : .on)
            return (settled ? nil : before.state.problem ?? "Tailscale isn't ready.", .skipped(before.state), before)
        }
        let arguments = action == .turnOff ? ["down"] : ["up"]
        // `up` waits until Tailscale is connected, which can take a while on a slow network. The
        // setting is changed before it starts waiting, so stopping it early loses nothing.
        let result = run(TailscaleApp.cli(inApp: app), arguments, timeout: action == .turnOff ? 15 : 20)
        let status = statusNow()
        let wanted: TailscaleState = action == .turnOff ? .off : .on
        if status.state == wanted {
            log.info("tailscale \(arguments[0], privacy: .public) succeeded")
            return (nil, .ran(succeeded: true, readBack: status.state), status)
        }
        let error = result.timedOut
            ? "Tailscale didn't answer."
            : result.exitStatus != 0
                ? TailscaleStatus.describe(errorOutput: result.errorOutput, exitStatus: result.exitStatus)
                : status.state.problem ?? (action == .turnOff ? "Tailscale is still on." : "Tailscale is still off.")
        log.error("tailscale \(arguments[0], privacy: .public) failed: \(error, privacy: .public)")
        let succeeded = !result.timedOut && result.exitStatus == 0
        return (error, .ran(succeeded: succeeded, readBack: status.state), status)
    }

    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> ProcessRunner.Result {
        ProcessRunner.run(executable, arguments,
                          environment: TailscaleApp.cliEnvironment(from: ProcessInfo.processInfo.environment),
                          timeout: timeout)
    }
}
