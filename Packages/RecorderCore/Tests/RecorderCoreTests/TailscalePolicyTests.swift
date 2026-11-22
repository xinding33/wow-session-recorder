import Foundation
import Testing
@testable import RecorderCore

private let wow = "WoW"
private let battleNet = "Battle.net"
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func inputs(_ open: [String], _ tailscale: TailscaleState, at seconds: TimeInterval = 0,
                    paused: Bool = false, blocked: TailscaleAction? = nil) -> TailscalePolicy.Inputs {
    TailscalePolicy.Inputs(open: open, tailscale: tailscale, paused: paused, grace: 10, blocked: blocked,
                  now: t0 + seconds)
}

@Suite struct PolicyTests {
    @Test func nothingHappensWithoutAWatchedApp() {
        #expect(TailscalePolicy.step(nil, inputs([], .on)) == TailscalePolicy.Step(session: nil))
        #expect(TailscalePolicy.step(nil, inputs([], .off)) == TailscalePolicy.Step(session: nil))
    }

    @Test func openingAWatchedAppTurnsTailscaleOff() {
        let step = TailscalePolicy.step(nil, inputs([wow], .on))
        #expect(step.action == .turnOff)
        #expect(step.session == TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"]))
    }

    @Test func tailscaleThatWasAlreadyOffStaysOffAfterwards() {
        var step = TailscalePolicy.step(nil, inputs([wow], .off))
        #expect(step.action == nil)
        #expect(step.session?.origin == .alreadyOff)
        step = TailscalePolicy.step(step.session, inputs([], .off, at: 60))
        #expect(step.action == nil)
        step = TailscalePolicy.step(step.session, inputs([], .off, at: 71))
        #expect(step == TailscalePolicy.Step(session: nil))
    }

    @Test func waitsForTailscaleBeforeDeciding() {
        var step = TailscalePolicy.step(nil, inputs([wow], .unknown))
        #expect(step.action == nil)
        #expect(step.session?.origin == .waiting)
        step = TailscalePolicy.step(step.session, inputs([wow], .unreachable("x"), at: 5))
        #expect(step.action == nil)
        step = TailscalePolicy.step(step.session, inputs([wow], .on, at: 10))
        #expect(step.action == .turnOff)
        #expect(step.session?.started == t0)
    }

    @Test func turnsBackOnOnlyAfterEveryWatchedAppQuitAndTheGracePeriod() {
        var session = TailscalePolicy.step(nil, inputs([wow], .on)).session
        var step = TailscalePolicy.step(session, inputs([wow, battleNet], .off, at: 30))
        #expect(step.action == nil)
        session = step.session
        step = TailscalePolicy.step(session, inputs([battleNet], .off, at: 40))
        #expect(step.action == nil)
        #expect(step.session?.lastQuit == nil)
        session = step.session
        step = TailscalePolicy.step(session, inputs([], .off, at: 50))
        #expect(step.action == nil)
        #expect(step.session?.lastQuit == t0 + 50)
        #expect(step.session?.apps == ["Battle.net"])
        session = step.session
        step = TailscalePolicy.step(session, inputs([], .off, at: 59))
        #expect(step.action == nil)
        step = TailscalePolicy.step(step.session, inputs([], .off, at: 60))
        #expect(step.action == .turnOn)
        #expect(TailscalePolicy.finished(.turnOn, .ran(succeeded: true, readBack: .on), session: step.session) == nil)
    }

    @Test func reopeningDuringTheGracePeriodCancelsIt() {
        var session = TailscalePolicy.step(nil, inputs([wow], .on)).session
        session = TailscalePolicy.step(session, inputs([], .off, at: 100)).session
        #expect(session?.lastQuit == t0 + 100)
        var step = TailscalePolicy.step(session, inputs([wow], .off, at: 105))
        #expect(step.action == nil)
        #expect(step.session?.lastQuit == nil)
        #expect(step.session?.origin == .turnedOff)
        step = TailscalePolicy.step(step.session, inputs([wow], .off, at: 200))
        #expect(step.action == nil)
    }

    @Test func zeroGraceTurnsBackOnAtOnce() {
        let session = TailscalePolicy.step(nil, inputs([wow], .on)).session
        var quit = inputs([], .off, at: 100)
        quit.grace = 0
        #expect(TailscalePolicy.step(session, quit).action == .turnOn)
    }

    @Test func turningTailscaleOnByHandIsLeftAloneUntilTheSessionEnds() {
        var session = TailscalePolicy.step(nil, inputs([wow], .on)).session
        var step = TailscalePolicy.step(session, inputs([wow], .on, at: 60))
        #expect(step.action == nil)
        #expect(step.session?.origin == .userTurnedOn)
        session = step.session
        // Off by hand again: still the user's business.
        step = TailscalePolicy.step(session, inputs([wow], .off, at: 70))
        #expect(step.action == nil)
        #expect(step.session?.origin == .userTurnedOn)
        // Quitting doesn't reconnect.
        step = TailscalePolicy.step(step.session, inputs([], .off, at: 80))
        #expect(step.action == nil)
        step = TailscalePolicy.step(step.session, inputs([], .off, at: 95))
        #expect(step == TailscalePolicy.Step(session: nil))
    }

    @Test func aQuickRelaunchAfterTurningItOnByHandDoesNotTurnItOff() {
        var session = TailscalePolicy.step(nil, inputs([wow], .on)).session
        session = TailscalePolicy.step(session, inputs([wow], .on, at: 60)).session
        session = TailscalePolicy.step(session, inputs([], .on, at: 70)).session
        let step = TailscalePolicy.step(session, inputs([wow], .on, at: 75))
        #expect(step.action == nil)
        #expect(step.session?.origin == .userTurnedOn)
    }

    @Test func turningItOnByHandDuringTheGracePeriodEndsTheSession() {
        var session = TailscalePolicy.step(nil, inputs([wow], .on)).session
        session = TailscalePolicy.step(session, inputs([], .off, at: 100)).session
        #expect(TailscalePolicy.step(session, inputs([], .on, at: 103)) == TailscalePolicy.Step(session: nil))
    }

    @Test func turningTheSettingOffHandsTailscaleBackImmediately() {
        let session = TailscalePolicy.step(nil, inputs([wow], .on)).session
        let step = TailscalePolicy.step(session, inputs([wow], .off, at: 30, paused: true))
        #expect(step.action == .turnOn)
    }

    @Test func turningTheSettingOffWithNothingToUndoEndsTheSession() {
        let session = TailscalePolicy.step(nil, inputs([wow], .off)).session
        #expect(TailscalePolicy.step(session, inputs([wow], .off, at: 30, paused: true)) == TailscalePolicy.Step(session: nil))
    }

    @Test func turnedOffInSettingsDoesNothing() {
        #expect(TailscalePolicy.step(nil, inputs([wow], .on, paused: true)) == TailscalePolicy.Step(session: nil))
    }

    @Test func turningTheSettingOnWithWoWOpenTurnsTailscaleOff() {
        #expect(TailscalePolicy.step(nil, inputs([wow], .on, at: 3600)).action == .turnOff)
    }

    @Test func aFailedTurnOffIsRetriedOnlyWhenAllowed() {
        let step = TailscalePolicy.step(nil, inputs([wow], .on))
        let session = TailscalePolicy.finished(.turnOff, .ran(succeeded: false, readBack: .on), session: step.session)
        #expect(session?.origin == .waiting)
        // Still on, and not mistaken for the user turning it on.
        var retry = TailscalePolicy.step(session, inputs([wow], .on, at: 5, blocked: .turnOff))
        #expect(retry.action == nil)
        #expect(retry.session?.origin == .waiting)
        retry = TailscalePolicy.step(retry.session, inputs([wow], .on, at: 30))
        #expect(retry.action == .turnOff)
    }

    @Test func aFailedTurnOnIsRetried() {
        var session = TailscalePolicy.step(nil, inputs([wow], .on)).session
        session = TailscalePolicy.step(session, inputs([], .off, at: 100)).session
        let step = TailscalePolicy.step(session, inputs([], .off, at: 110))
        #expect(step.action == .turnOn)
        session = TailscalePolicy.finished(.turnOn, .ran(succeeded: false, readBack: .unreachable("x")), session: step.session)
        #expect(session?.origin == .turnedOff)
        #expect(TailscalePolicy.step(session, inputs([], .off, at: 120, blocked: .turnOn)).action == nil)
        #expect(TailscalePolicy.step(session, inputs([], .off, at: 140)).action == .turnOn)
    }

    @Test func keepsThePromiseWhileTailscaleIsUnreachable() {
        var session = TailscalePolicy.step(nil, inputs([wow], .on)).session
        var step = TailscalePolicy.step(session, inputs([], .unreachable("Tailscale isn't running."), at: 100))
        #expect(step.action == nil)
        #expect(step.session?.origin == .turnedOff)
        session = step.session
        step = TailscalePolicy.step(session, inputs([], .off, at: 300))
        #expect(step.action == .turnOn)
    }

    /// After a crash or restart, the saved session turns Tailscale back on.
    @Test func aSavedSessionWithNoAppOpenReconnects() {
        let saved = TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"])
        var step = TailscalePolicy.step(saved, inputs([], .off, at: 3600))
        #expect(step.action == nil)
        step = TailscalePolicy.step(step.session, inputs([], .off, at: 3610))
        #expect(step.action == .turnOn)
    }

    /// `down` may have worked even if reading the state back failed, so the promise stays.
    @Test func anUnreadableStateAfterTurningOffKeepsThePromise() {
        let step = TailscalePolicy.step(nil, inputs([wow], .on))
        for readBack in [TailscaleState.unreachable("Tailscale didn't answer."), .unknown, .off] {
            #expect(TailscalePolicy.finished(.turnOff, .ran(succeeded: false, readBack: readBack), session: step.session)?.origin == .turnedOff)
        }
        let session = TailscalePolicy.finished(.turnOff, .ran(succeeded: false, readBack: .unknown), session: step.session)
        let quit = TailscalePolicy.step(session, inputs([], .off, at: 100))
        #expect(quit.session?.origin == .turnedOff)
        #expect(TailscalePolicy.step(quit.session, inputs([], .off, at: 110)).action == .turnOn)
    }

    /// The user turned Tailscale off just before opening the app; the last read still says on.
    @Test func aNewSessionWaitsForAReadFromAfterItBegan() {
        let stale = TailscalePolicy.Inputs(open: [wow], tailscale: .on, tailscaleAsOf: t0 - 20, now: t0)
        let step = TailscalePolicy.step(nil, stale)
        #expect(step.action == nil)
        #expect(step.session?.origin == .waiting)
        #expect(TailscalePolicy.needsFreshStatus(step.session, stale))
        let fresh = TailscalePolicy.Inputs(open: [wow], tailscale: .off, tailscaleAsOf: t0 + 0.5, now: t0 + 1)
        #expect(!TailscalePolicy.needsFreshStatus(step.session, fresh))
        let decided = TailscalePolicy.step(step.session, fresh)
        #expect(decided.action == nil)
        #expect(decided.session?.origin == .alreadyOff)
    }

    @Test func aStaleOffDoesNotDecideEither() {
        let stale = TailscalePolicy.Inputs(open: [wow], tailscale: .off, tailscaleAsOf: t0 - 1, now: t0)
        #expect(TailscalePolicy.step(nil, stale).session?.origin == .waiting)
    }

    @Test func removingTheOpenAppFromTheListEndsTheSession() {
        let session = TailscalePolicy.step(nil, inputs([wow], .on)).session
        var step = TailscalePolicy.step(session, inputs([], .off, at: 50))
        #expect(step.session?.lastQuit == t0 + 50)
        step = TailscalePolicy.step(step.session, inputs([], .off, at: 60))
        #expect(step.action == .turnOn)
    }

    @Test func aWatchedAppOpeningDuringTheGracePeriodAfterAFailedTurnOnKeepsTailscaleOff() {
        var session = TailscalePolicy.step(nil, inputs([wow], .on)).session
        session = TailscalePolicy.step(session, inputs([], .off, at: 100)).session
        session = TailscalePolicy.finished(.turnOn, .ran(succeeded: false, readBack: .off), session: TailscalePolicy.step(session, inputs([], .off, at: 110)).session)
        let step = TailscalePolicy.step(session, inputs([battleNet], .off, at: 115, blocked: .turnOn))
        #expect(step.action == nil)
        #expect(step.session?.origin == .turnedOff)
        #expect(step.session?.lastQuit == nil)
    }

    /// Decided on an older read, but the user turned Tailscale off before the command ran.
    @Test func aTurnOffSkippedBecauseItWasAlreadyOffIsNotTheApps() {
        let step = TailscalePolicy.step(nil, inputs([wow], .on))
        let session = TailscalePolicy.finished(.turnOff, .skipped(.off), session: step.session)
        #expect(session?.origin == .alreadyOff)
        var quit = TailscalePolicy.step(session, inputs([], .off, at: 100))
        quit = TailscalePolicy.step(quit.session, inputs([], .off, at: 200))
        #expect(quit == TailscalePolicy.Step(session: nil))
    }

    @Test func aTurnOffSkippedBecauseTailscaleWasUnreachableWaits() {
        let step = TailscalePolicy.step(nil, inputs([wow], .on))
        #expect(TailscalePolicy.finished(.turnOff, .skipped(.unreachable("x")), session: step.session)?.origin == .waiting)
    }

    @Test func aTurnOnSkippedBecauseItWasAlreadyOnEndsTheSession() {
        let session = TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"], lastQuit: t0)
        #expect(TailscalePolicy.finished(.turnOn, .skipped(.on), session: session) == nil)
        #expect(TailscalePolicy.finished(.turnOn, .skipped(.needsLogin), session: session) == session)
    }

    @Test func outcomesThatRanUseTheReadBack() {
        let session = TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"])
        #expect(TailscalePolicy.finished(.turnOff, .ran(succeeded: true, readBack: .off), session: session) == session)
        #expect(TailscalePolicy.finished(.turnOff, .ran(succeeded: false, readBack: .on), session: session)?.origin == .waiting)
        #expect(TailscalePolicy.finished(.turnOn, .ran(succeeded: true, readBack: .on), session: session) == nil)
        #expect(TailscalePolicy.finished(.turnOn, .ran(succeeded: false, readBack: .off), session: session) == session)
    }

    /// `down` worked, then the user turned Tailscale back on before it was read back.
    @Test func aReconnectBeforeTheReadBackIsTheUsers() {
        let session = TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"])
        #expect(TailscalePolicy.finished(.turnOff, .ran(succeeded: true, readBack: .on), session: session)?.origin == .userTurnedOn)
    }
}
