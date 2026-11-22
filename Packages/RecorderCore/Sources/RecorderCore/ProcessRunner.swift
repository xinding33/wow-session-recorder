import Foundation

/// Runs a command line tool with a deadline. Blocks, so call it off the main thread.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var exitStatus: Int32 = -1
        public var output = Data()
        public var errorOutput = ""
        public var timedOut = false
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    /// Stops the process at `timeout`: SIGTERM, then SIGKILL if it's still there after `grace`.
    /// Returns even if the process can't be reaped, so a wedged tool never blocks the caller.
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval, grace: TimeInterval = 2) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        var result = Result()
        do {
            try process.run()
        } catch {
            result.errorOutput = error.localizedDescription
            return result
        }
        // Read both pipes while the process runs, so a full pipe can't stall it. On threads of
        // their own: blocking reads on GCD's pool can wait behind other blocked work for seconds
        // (CI's test runner lost the output that way).
        let out = Box(), err = Box()
        let reads = DispatchGroup()
        for (pipe, box) in [(outPipe, out), (errPipe, err)] {
            reads.enter()
            Thread {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                reads.leave()
            }.start()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            result.timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + grace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                // SIGKILL can't be ignored, but a process stuck in the kernel can't die either.
                guard exited.wait(timeout: .now() + grace) == .success else { return result }
            }
        }
        result.exitStatus = process.terminationStatus
        // A child process that kept the pipes open would block the reads forever.
        guard reads.wait(timeout: .now() + 5) == .success else { return result }
        result.output = out.data
        result.errorOutput = String(decoding: err.data, as: UTF8.self)
        return result
    }
}
