import Foundation

/// Splits a growing byte stream into lines.
///
/// WoW writes the combat log with CRLF endings and flushes in arbitrary chunks, so a read can
/// end mid-line; the unfinished tail is held until the next `append`.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
            var lineEnd = newline
            if lineEnd > lineStart, pending[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            lines.append(String(decoding: pending[lineStart..<lineEnd], as: UTF8.self))
            lineStart = newline + 1
        }
        pending = Data(pending[lineStart...])
        return lines
    }

    /// Drops any partial line, e.g. when switching to a new log file.
    public mutating func reset() {
        pending.removeAll()
    }
}
