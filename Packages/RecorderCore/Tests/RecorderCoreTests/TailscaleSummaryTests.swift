import Foundation
import Testing
@testable import RecorderCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func summary(_ session: TailscaleSession?, _ tailscale: TailscaleState = .on, enabled: Bool = true,
                     lastError: String? = nil, at seconds: TimeInterval = 0) -> TailscaleSummary? {
    TailscaleSummary.make(TailscaleSummary.Inputs(session: session, tailscale: tailscale, enabled: enabled,
                                                  lastError: lastError, now: t0 + seconds,
                                                  time: { "T+\(Int($0.timeIntervalSince(t0)))" }))
}

@Suite struct TailscaleSummaryTests {
    @Test func idle() {
        #expect(summary(nil) == TailscaleSummary(title: "Tailscale is on", detail: "It's turned off while WoW is running."))
        #expect(summary(nil, .off)?.title == "Tailscale is off")
        #expect(summary(nil, .unknown)?.title == "Checking Tailscale…")
    }

    @Test func offWhileWoWRuns() {
        let session = TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"])
        #expect(summary(session, .off, at: 60) == TailscaleSummary(
            title: "Tailscale is off while WoW runs", detail: "Since T+0. Turns back on 10 s after it quits."))
    }

    @Test func gracePeriodCountsDown() {
        let session = TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"], lastQuit: t0 + 100)
        #expect(summary(session, .off, at: 103) == TailscaleSummary(
            title: "Turning Tailscale on in 7 s", detail: "WoW quit. Reopening it cancels this."))
        #expect(summary(session, .off, at: 110)?.title == "Turning Tailscale on…")
    }

    @Test func leftAlone() {
        #expect(summary(TailscaleSession(origin: .userTurnedOn, started: t0, apps: ["WoW"])) == TailscaleSummary(
            title: "You turned Tailscale back on", detail: "It's left alone until WoW quits."))
        #expect(summary(TailscaleSession(origin: .alreadyOff, started: t0, apps: ["WoW"]), .off) == TailscaleSummary(
            title: "Tailscale was already off", detail: "It stays off after WoW quits."))
    }

    @Test func turnedOffInSettingsSaysNothing() {
        #expect(summary(nil, enabled: false) == nil)
        #expect(summary(nil, .notInstalled, enabled: false) == nil)
        #expect(summary(TailscaleSession(origin: .alreadyOff, started: t0, apps: ["WoW"]), .off, enabled: false) == nil)
    }

    @Test func turningTheSettingOffShowsTheHandBackUntilItWorks() {
        let session = TailscaleSession(origin: .turnedOff, started: t0, apps: ["WoW"])
        #expect(summary(session, .off, enabled: false)?.title == "Turning Tailscale back on…")
        let failed = summary(session, .off, enabled: false, lastError: "boom")
        #expect(failed?.title == "Couldn't turn Tailscale on")
        #expect(failed?.isProblem == true)
    }

    @Test func problems() {
        #expect(summary(nil, .unreachable("Tailscale isn't running.")) == TailscaleSummary(
            title: "Can't reach Tailscale", detail: "Tailscale isn't running. Retries every 30 s.",
            isProblem: true, fix: .openTailscale))
        #expect(summary(nil, .notInstalled)?.fix == .getTailscale)
        #expect(summary(nil, .needsLogin)?.isProblem == true)
        let failedOff = summary(TailscaleSession(origin: .waiting, started: t0, apps: ["WoW"]), .on, lastError: "boom")
        #expect(failedOff?.title == "Couldn't turn Tailscale off")
    }

    @Test func lists() {
        #expect(TailscaleSummary.list(["A"]) == "A")
        #expect(TailscaleSummary.list(["A", "B"]) == "A and B")
        #expect(TailscaleSummary.list(["A", "B", "C"]) == "A, B and C")
        #expect(TailscaleSummary.list(["A", "B", "C", "D"]) == "4 apps")
    }
}

@Suite struct TailscaleStatusTests {
    private func parse(_ json: String, exit: Int32 = 0, error: String = "") -> TailscaleStatus {
        TailscaleStatus.parse(output: Data(json.utf8), exitStatus: exit, errorOutput: error)
    }

    @Test func backendStates() {
        #expect(parse(#"{"BackendState":"Running","Version":"1.104.1-t7f4efe814-g4939ea2e4"}"#)
            == TailscaleStatus(state: .on, version: "1.104.1"))
        #expect(parse(#"{"BackendState":"Starting"}"#).state == .on)
        #expect(parse(#"{"BackendState":"Stopped"}"#, exit: 1).state == .off)
        #expect(parse(#"{"BackendState":"NeedsLogin"}"#).state == .needsLogin)
        #expect(parse(#"{"BackendState":"NeedsMachineAuth"}"#).state == .needsLogin)
        #expect(parse(#"{"BackendState":"NoState"}"#).state.isControllable == false)
    }

    @Test func failures() {
        let notRunning = parse("", exit: 1,
                               error: "failed to connect to local Tailscale service; is Tailscale running?\n")
        #expect(notRunning.state == .unreachable("Tailscale isn't running."))
        #expect(parse("", exit: 2).state == .unreachable("The Tailscale CLI failed (exit status 2)."))
        #expect(parse("nope", exit: 1, error: "first line\nusage").state == .unreachable("first line"))
    }

    /// Launched by launchd, the app has no TERM or SHLVL, and without TAILSCALE_BE_CLI Tailscale's
    /// binary starts as a GUI instead of the CLI.
    @Test func cliEnvironmentForcesTheCLIAndDropsSSH() {
        let launchd = ["HOME": "/Users/me", "PATH": "/usr/bin:/bin", "XPC_SERVICE_NAME": "x",
                       "SSH_AUTH_SOCK": "/tmp/sock", "TAILSCALE_BE_CLI": "0"]
        #expect(TailscaleApp.cliEnvironment(from: launchd)
            == ["HOME": "/Users/me", "PATH": "/usr/bin:/bin", "XPC_SERVICE_NAME": "x", "TAILSCALE_BE_CLI": "1"])
    }
}

@Suite struct JSONStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RecorderCoreTests-\(UUID().uuidString)/session.json")
    }

    @Test func sessionsRoundTrip() throws {
        let store = JSONStore<TailscaleSession>(url: temporaryURL())
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        #expect(store.load() == nil)
        let session = TailscaleSession(origin: .turnedOff, started: Date(timeIntervalSince1970: 1_800_000_000),
                                       apps: ["WoW"], lastQuit: Date(timeIntervalSince1970: 1_800_000_100))
        try store.save(session)
        #expect(JSONStore<TailscaleSession>(url: store.url).load() == session)
        try store.remove()
        #expect(store.load() == nil)
    }

    @Test func refusesToOverwriteAFileItCouldNotRead() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = JSONStore<TailscaleSession>(url: url)
        #expect(store.load() == nil)
        #expect(throws: StoreError.self) { try store.save(TailscaleSession(origin: .waiting, started: .now, apps: [])) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }
}
