import Foundation
import Testing
@testable import RecorderCore

private let wow = "WoW"
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Records what was written, and can be told to fail.
private final class Disk: @unchecked Sendable {
    struct Failure: Error {}
    var writes: [TailscaleSession?] = []
    var failing = false

    func persist(_ session: TailscaleSession?) throws {
        if failing { throw Failure() }
        writes.append(session)
    }
}

private func coordinator(_ disk: Disk, session: TailscaleSession? = nil) -> TailscaleCoordinator {
    TailscaleCoordinator(session: session) { try disk.persist($0) }
}

private func inputs(_ open: [String], _ tailscale: TailscaleState, at seconds: TimeInterval = 0,
                    paused: Bool = false) -> TailscalePolicy.Inputs {
    TailscalePolicy.Inputs(open: open, tailscale: tailscale, paused: paused, grace: 10, now: t0 + seconds)
}

@Suite struct CoordinatorTests {
    @Test func savesBeforeTurningOff() {
        let disk = Disk()
        var c = coordinator(disk)
        #expect(c.evaluate(inputs([wow], .on)) == .run(.turnOff))
        #expect(disk.writes.last??.origin == .turnedOff)
        #expect(c.running == .turnOff)
        // Nothing else is decided while it runs.
        #expect(c.evaluate(inputs([], .off, at: 1)) == nil)
    }

    @Test func doesNotTurnOffWhenItCannotSave() {
        let disk = Disk()
        disk.failing = true
        var c = coordinator(disk)
        #expect(c.evaluate(inputs([wow], .on)) == nil)
        #expect(c.session?.origin == .waiting)
        #expect(c.lastError == "WoW Session Recorder couldn't save its state.")
        #expect(c.evaluate(inputs([wow], .on, at: 10)) == nil)
        disk.failing = false
        #expect(c.evaluate(inputs([wow], .on, at: 31)) == .run(.turnOff))
        #expect(disk.writes.last??.origin == .turnedOff)
    }

    @Test func retriesAFailedWriteEvenWithNothingNew() {
        let disk = Disk()
        var c = coordinator(disk)
        _ = c.evaluate(inputs([wow], .on))
        _ = c.finished(.turnOff, .ran(succeeded: true, readBack: .off), error: nil, now: t0 + 1)
        disk.failing = true
        _ = c.evaluate(inputs([], .off, at: 100))
        #expect(c.evaluate(inputs([], .off, at: 110)) == .run(.turnOn))
        _ = c.finished(.turnOn, .ran(succeeded: true, readBack: .on), error: nil, now: t0 + 111)
        #expect(c.session == nil)
        let writes = disk.writes.count
        disk.failing = false
        _ = c.evaluate(inputs([], .on, at: 120))
        #expect(disk.writes.count == writes + 1)
        #expect(disk.writes.last! == nil)
    }

    /// R3-1: `down` worked, then the user reconnected before the read-back.
    @Test func aReconnectDuringTheReadBackIsLeftAlone() {
        var c = coordinator(Disk())
        _ = c.evaluate(inputs([wow], .on))
        _ = c.finished(.turnOff, .ran(succeeded: true, readBack: .on), error: "Tailscale is still on.", now: t0 + 1)
        #expect(c.session?.origin == .userTurnedOn)
        #expect(c.lastError == nil)
        #expect(c.evaluate(inputs([wow], .on, at: 60)) == nil)
    }

    @Test func aDownThatFailedIsRetriedAfterTheCooldown() {
        var c = coordinator(Disk())
        _ = c.evaluate(inputs([wow], .on))
        _ = c.finished(.turnOff, .ran(succeeded: false, readBack: .on), error: "boom", now: t0 + 1)
        #expect(c.session?.origin == .waiting)
        #expect(c.lastError == "boom")
        #expect(c.evaluate(inputs([wow], .on, at: 20)) == nil)
        #expect(c.evaluate(inputs([wow], .on, at: 31)) == .run(.turnOff))
    }

    /// R3-2: a failed `down` mustn't hold up turning the setting off from handing Tailscale back.
    @Test func aTurnOffCooldownDoesNotDelayTheHandBack() {
        var c = coordinator(Disk())
        _ = c.evaluate(inputs([wow], .on))
        _ = c.finished(.turnOff, .ran(succeeded: false, readBack: .unreachable("x")), error: "x", now: t0 + 1)
        #expect(c.session?.origin == .turnedOff)
        #expect(c.cooldown?.action == .turnOff)
        #expect(c.evaluate(inputs([wow], .off, at: 5, paused: true)) == .run(.turnOn))
    }

    /// R3-3: a skipped command's error goes once there's nothing left to do.
    @Test func aResolvedErrorIsCleared() {
        var c = coordinator(Disk())
        _ = c.evaluate(inputs([wow], .on))
        _ = c.finished(.turnOff, .skipped(.unreachable("Tailscale isn't running.")), error: "Tailscale isn't running.",
                       now: t0 + 1)
        #expect(c.session?.origin == .waiting)
        #expect(c.lastError != nil)
        #expect(c.evaluate(inputs([wow], .off, at: 5)) == nil)
        #expect(c.session?.origin == .alreadyOff)
        #expect(c.lastError == nil)
        #expect(c.cooldown == nil)
    }

    @Test func aTurnOffWhoseReadBackFailedIsClearedOnceItReadsOff() {
        var c = coordinator(Disk())
        _ = c.evaluate(inputs([wow], .on))
        _ = c.finished(.turnOff, .ran(succeeded: true, readBack: .unreachable("x")), error: "x", now: t0 + 1)
        #expect(c.lastError == "x")
        _ = c.evaluate(inputs([wow], .off, at: 5))
        #expect(c.lastError == nil)
        #expect(c.session?.origin == .turnedOff)
    }

    @Test func aFailedTurnOnIsRetriedAfterTheCooldown() {
        var c = coordinator(Disk(), session: TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"]))
        _ = c.evaluate(inputs([], .off, at: 100))
        #expect(c.evaluate(inputs([], .off, at: 110)) == .run(.turnOn))
        _ = c.finished(.turnOn, .ran(succeeded: false, readBack: .off), error: "boom", now: t0 + 111)
        #expect(c.evaluate(inputs([], .off, at: 120)) == nil)
        #expect(c.evaluate(inputs([], .off, at: 142)) == .run(.turnOn))
    }

    @Test func quittingIdleWithNothingToUndo() {
        var c = coordinator(Disk())
        #expect(!c.mustWaitBeforeQuitting(handBack: true))
        #expect(c.quit(handBack: true) == .quit)
    }

    @Test func quittingHandsBack() {
        var c = coordinator(Disk(), session: TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"]))
        #expect(c.mustWaitBeforeQuitting(handBack: true))
        #expect(!c.mustWaitBeforeQuitting(handBack: false))
        #expect(c.quit(handBack: true) == .run(.turnOn))
        #expect(c.finished(.turnOn, .ran(succeeded: true, readBack: .on), error: nil, now: t0) == .quit)
        #expect(c.session == nil)
    }

    @Test func aFailedHandBackStaysSavedForTheNextLaunch() {
        let disk = Disk()
        var c = coordinator(disk, session: TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"]))
        _ = c.quit(handBack: true)
        #expect(c.finished(.turnOn, .ran(succeeded: false, readBack: .off), error: "boom", now: t0) == .quit)
        #expect(c.session?.origin == .turnedOff)
        #expect(!disk.writes.contains { $0 == nil })
    }

    @Test func quittingDuringDownWaitsThenHandsBack() {
        var c = coordinator(Disk())
        _ = c.evaluate(inputs([wow], .on))
        #expect(c.mustWaitBeforeQuitting(handBack: false))
        #expect(c.quit(handBack: true) == nil)
        #expect(c.evaluate(inputs([wow], .on, at: 1)) == nil)
        #expect(c.finished(.turnOff, .ran(succeeded: true, readBack: .off), error: nil, now: t0 + 1) == .run(.turnOn))
        #expect(c.finished(.turnOn, .ran(succeeded: true, readBack: .on), error: nil, now: t0 + 2) == .quit)
    }

    @Test func quittingDuringUpWaitsForIt() {
        var c = coordinator(Disk(), session: TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"]))
        _ = c.evaluate(inputs([], .off, at: 100))
        #expect(c.evaluate(inputs([], .off, at: 110)) == .run(.turnOn))
        #expect(c.quit(handBack: true) == nil)
        #expect(c.finished(.turnOn, .ran(succeeded: true, readBack: .on), error: nil, now: t0 + 111) == .quit)
    }

    /// An update relaunch waits for `down` and leaves Tailscale off for the new copy.
    @Test func relaunchingDuringDownKeepsThePromiseSaved() {
        let disk = Disk()
        var c = coordinator(disk)
        _ = c.evaluate(inputs([wow], .on))
        #expect(c.quit(handBack: false) == nil)
        #expect(c.finished(.turnOff, .ran(succeeded: true, readBack: .off), error: nil, now: t0 + 1) == .quit)
        #expect(disk.writes.last??.origin == .turnedOff)
    }

    /// R4-1: reopening a watched app makes a failed hand-back moot, so its cooldown mustn't
    /// delay the next one.
    @Test func reopeningAfterAFailedHandBackClearsIt() {
        var c = coordinator(Disk(), session: TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"]))
        _ = c.evaluate(inputs([], .off, at: 100))
        #expect(c.evaluate(inputs([], .off, at: 110)) == .run(.turnOn))
        _ = c.finished(.turnOn, .ran(succeeded: false, readBack: .off), error: "boom", now: t0 + 110)
        #expect(c.evaluate(inputs([wow], .off, at: 111)) == nil)
        #expect(c.lastError == nil)
        #expect(c.cooldown == nil)
        _ = c.evaluate(inputs([], .off, at: 112))
        #expect(c.evaluate(inputs([], .off, at: 121)) == nil)
        #expect(c.evaluate(inputs([], .off, at: 122)) == .run(.turnOn))
    }

    @Test func aFailedHandBackStillShowsWhileNoAppIsOpen() {
        var c = coordinator(Disk(), session: TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"]))
        _ = c.evaluate(inputs([], .off, at: 100))
        _ = c.evaluate(inputs([], .off, at: 110))
        _ = c.finished(.turnOn, .ran(succeeded: false, readBack: .off), error: "boom", now: t0 + 110)
        #expect(c.evaluate(inputs([], .off, at: 115)) == nil)
        #expect(c.lastError == "boom")
        // Turned off in Settings with WoW open: the hand-back is still owed.
        #expect(c.evaluate(inputs([wow], .off, at: 116, paused: true)) == nil)
        #expect(c.lastError == "boom")
    }
}
