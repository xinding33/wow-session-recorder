import Foundation

/// A finished chunk of recorded footage on disk.
///
/// Segments are named `seg_<startMs>_<endMs>.mp4` (Unix epoch milliseconds), so the index can
/// be rebuilt from a directory listing alone. In-progress segments end in `.partial.mp4`
/// and are ignored until the writer renames them.
public struct Segment: Sendable, Hashable, Identifiable {
    public var url: URL
    public var start: Date
    public var end: Date

    public var id: URL { url }
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public init(url: URL, start: Date, end: Date) {
        self.url = url
        self.start = start
        self.end = end
    }

    public func overlaps(_ start: Date, _ end: Date) -> Bool {
        self.start < end && self.end > start
    }
}

public enum SegmentNaming {
    public static func finalName(start: Date, end: Date) -> String {
        "seg_\(millis(start))_\(millis(end)).mp4"
    }

    public static func partialName(start: Date) -> String {
        "seg_\(millis(start)).partial.mp4"
    }

    public static func parse(_ url: URL) -> Segment? {
        let name = url.lastPathComponent
        guard name.hasPrefix("seg_"), name.hasSuffix(".mp4"), !name.hasSuffix(".partial.mp4") else { return nil }
        let parts = name.dropFirst(4).dropLast(4).split(separator: "_")
        guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]), end > start else { return nil }
        return Segment(url: url, start: date(start), end: date(end))
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}

/// A contiguous run of segments, i.e. one uninterrupted stretch of recording.
public struct FootageSession: Sendable, Hashable, Identifiable {
    public var segments: [Segment]
    public var id: Date { start }
    public var start: Date { segments.first!.start }
    public var end: Date { segments.last!.end }
}

public enum SegmentIndex {
    public static func scan(directory: URL) -> [Segment] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap(SegmentNaming.parse).sorted { $0.start < $1.start }
    }

    /// Segments (sorted by start) that overlap `[start, end)`.
    public static func overlapping(_ segments: [Segment], start: Date, end: Date) -> [Segment] {
        segments.filter { $0.overlaps(start, end) }
    }

    /// Groups sorted segments into sessions, splitting wherever recording paused for longer
    /// than `maxGap`.
    public static func sessions(_ segments: [Segment], maxGap: TimeInterval = 5) -> [FootageSession] {
        var sessions: [FootageSession] = []
        for segment in segments {
            if var last = sessions.last, segment.start.timeIntervalSince(last.end) <= maxGap {
                last.segments.append(segment)
                sessions[sessions.count - 1] = last
            } else {
                sessions.append(FootageSession(segments: [segment]))
            }
        }
        return sessions
    }
}
