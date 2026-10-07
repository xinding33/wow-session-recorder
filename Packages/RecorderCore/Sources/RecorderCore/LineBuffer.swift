import Foundation

/// Splits a growing byte stream into lines.
///
/// WoW writes the combat log with CRLF endings and flushes in arbitrary chunks, so a read can
/// end mid-line; the unfinished tail is held until the next `append`.
public struct LineBuffer: Sendable {
    private var pending = Data()
    /// Stream offset of the first byte in `pending`.
    private var pendingOffset: UInt64

    /// - Parameter startOffset: Where in the file the first appended byte sits, so lines can
    ///   report their byte offsets.
    public init(startOffset: UInt64 = 0) {
        pendingOffset = startOffset
    }

    public mutating func append(_ data: Data) -> [String] {
        appendWithOffsets(data).map(\.line)
    }

    /// Like `append`, also returning each line's starting byte offset in the stream.
    public mutating func appendWithOffsets(_ data: Data) -> [(line: String, offset: UInt64)] {
        pending.append(data)
        var lines: [(String, UInt64)] = []
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
            var lineEnd = newline
            if lineEnd > lineStart, pending[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            let offset = pendingOffset + UInt64(lineStart - pending.startIndex)
            lines.append((String(decoding: pending[lineStart..<lineEnd], as: UTF8.self), offset))
            lineStart = newline + 1
        }
        pendingOffset += UInt64(lineStart - pending.startIndex)
        pending = Data(pending[lineStart...])
        return lines
    }

    /// Drops any partial line, e.g. when switching to a new log file.
    public mutating func reset(startOffset: UInt64 = 0) {
        pending.removeAll()
        pendingOffset = startOffset
    }
}
