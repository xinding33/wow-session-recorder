import Foundation
import Testing
@testable import RecorderCore

@Suite struct ProcessRunnerTests {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    @Test func capturesOutputAndStatus() {
        let result = ProcessRunner.run(sh, ["-c", "echo out; echo err >&2; exit 3"], timeout: 5)
        #expect(result.exitStatus == 3)
        #expect(String(decoding: result.output, as: UTF8.self) == "out\n")
        #expect(result.errorOutput == "err\n")
        #expect(!result.timedOut)
    }

    @Test func stopsAProcessAtTheDeadline() {
        let start = Date()
        let result = ProcessRunner.run(sh, ["-c", "sleep 30"], timeout: 0.5)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    /// A tool that ignores SIGTERM is killed, so it can't hold the queue forever.
    @Test func killsAProcessThatIgnoresTerminate() {
        let start = Date()
        let result = ProcessRunner.run(sh, ["-c", "trap '' TERM; while :; do sleep 0.1; done"], timeout: 0.5, grace: 0.5)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
