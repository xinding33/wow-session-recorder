import Foundation

/// Copies the part of the combat log that some activities cover into a file of its own, so
/// just those activities can be uploaded to Warcraft Logs instead of the whole night.
public enum CombatLogSplit {
    public enum SplitError: Error, Equatable {
        /// The activity was recorded before activities remembered where they are in the log.
        case notLogged(title: String)
        case inProgress(title: String)
        /// The log file has been deleted or moved out of the Logs folder.
        case logMissing(fileName: String)
        /// A clip saved while its activity was still going, whose activity has since been deleted,
        /// so where it ends in the log is unknown.
        case endUnknown(title: String)
    }

    /// Where the activities live in the log, in log order. Ranges that overlap, like a key and a
    /// clip from it, are merged so no line is copied twice.
    ///
    /// `library` is searched for the activity a clip came from: a clip saved while it was still
    /// going copied its range before the end was known.
    public static func ranges(for activities: [Activity], in library: [Activity] = []) throws -> [LogRange] {
        var found: [LogRange] = []
        for activity in activities {
            guard !activity.isInProgress else { throw SplitError.inProgress(title: activity.title) }
            guard var range = activity.log else { throw SplitError.notLogged(title: activity.title) }
            if activity.kind == .clip, range.endOffset == nil {
                guard let source = (library + activities).first(where: {
                    $0.kind != .clip && $0.log?.fileName == range.fileName && $0.log?.startOffset == range.startOffset
                }) else { throw SplitError.endUnknown(title: activity.title) }
                guard !source.isInProgress, let sourceRange = source.log else {
                    throw SplitError.inProgress(title: source.title)
                }
                range = sourceRange
            }
            found.append(range)
        }
        // Clips can start later than the activity after the one they came from, so time order
        // isn't log order. Logs are named by when they started.
        found.sort {
            let a = CombatLogFiles.startDate(fileName: $0.fileName) ?? .distantPast
            let b = CombatLogFiles.startDate(fileName: $1.fileName) ?? .distantPast
            return (a, $0.fileName, $0.startOffset) < (b, $1.fileName, $1.startOffset)
        }
        var ranges: [LogRange] = []
        for range in found {
            // A range without an end runs to the end of its log, so it covers everything after it.
            if var last = ranges.last, last.fileName == range.fileName,
               last.endOffset.map({ range.startOffset <= $0 }) ?? true {
                if let lastEnd = last.endOffset {
                    last.endOffset = range.endOffset.map { max($0, lastEnd) }
                }
                ranges[ranges.count - 1] = last
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// Writes `ranges` from the logs in `logs` to `destination`. Each log's first line, its
    /// `COMBAT_LOG_VERSION` header, goes in before its ranges, as Warcraft Logs needs it to read
    /// the file. A range without an end runs to the end of its log.
    public static func write(_ ranges: [LogRange], from logs: URL, to destination: URL) throws {
        let fm = FileManager.default
        for name in Set(ranges.map(\.fileName)) where !fm.fileExists(atPath: logs.appending(path: name).path) {
            throw SplitError.logMissing(fileName: name)
        }
        let partial = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).partial")
        guard fm.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            var previousFile: String?
            for range in ranges {
                let input = try FileHandle(forReadingFrom: logs.appending(path: range.fileName))
                defer { try? input.close() }
                let size = try input.seekToEnd()
                if range.fileName != previousFile, range.startOffset > 0,
                   let header = try headerLine(input), header.count <= range.startOffset {
                    try output.write(contentsOf: header)
                }
                previousFile = range.fileName
                let end = try range.endOffset.map { try endOfLine(at: $0, in: input, size: size) } ?? size
                try copy(input, from: range.startOffset, to: end, into: output)
            }
            try output.synchronize()
            try output.close()
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// Named like the Archon app's own split logs, e.g. `Split-Ara-Kara +12-2026-10-14T213012.txt`,
    /// with a code for the selection when there are several.
    /// The same activities always get the same name, so saving them again replaces the file.
    /// It doesn't start with `WoWCombatLog`, so log followers (this app's and Archon's live
    /// logging) never mistake it for the log WoW is writing.
    public static func fileName(for activities: [Activity], timeZone: TimeZone = .current) -> String {
        let sorted = activities.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return "Split.txt" }
        var label = first.title
        if sorted.count > 1 { label += " and \(sorted.count - 1) more" }
        // Finder shows a colon as a slash, and a slash can't be in a name.
        label = label.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "/", with: "-")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        var name = "Split-\(label)-\(formatter.string(from: first.start))"
        // Different selections starting with the same activity would otherwise share a name.
        if sorted.count > 1 { name += "-" + selectionCode(sorted.map(\.id)) }
        return name + ".txt"
    }

    /// Six hex digits that stay the same for the same activities, unlike `Hasher`'s.
    private static func selectionCode(_ ids: [UUID]) -> String {
        var hash: UInt32 = 2_166_136_261  // FNV-1a
        for byte in ids.map(\.uuidString).sorted().joined(separator: ",").utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%06x", hash & 0xFFFFFF)
    }

    /// The log's first line, newline included, if it's the version header.
    private static func headerLine(_ handle: FileHandle) throws -> Data? {
        try handle.seek(toOffset: 0)
        guard let chunk = try handle.read(upToCount: 4096),
              let newline = chunk.firstIndex(of: 0x0A) else { return nil }
        let line = chunk[chunk.startIndex...newline]
        guard String(decoding: line, as: UTF8.self).contains("COMBAT_LOG_VERSION") else { return nil }
        return Data(line)
    }

    /// Just past the newline ending the line that starts at `offset`.
    private static func endOfLine(at offset: UInt64, in handle: FileHandle, size: UInt64) throws -> UInt64 {
        var position = min(offset, size)
        try handle.seek(toOffset: position)
        while position < size {
            guard let chunk = try handle.read(upToCount: 64 << 10), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                return position + UInt64(newline - chunk.startIndex) + 1
            }
            position += UInt64(chunk.count)
        }
        return size
    }

    private static func copy(_ input: FileHandle, from start: UInt64, to end: UInt64, into output: FileHandle) throws {
        guard end > start else { return }
        try input.seek(toOffset: start)
        var remaining = end - start
        while remaining > 0 {
            let count = Int(min(remaining, 8 << 20))
            guard let chunk = try input.read(upToCount: count), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }
}
