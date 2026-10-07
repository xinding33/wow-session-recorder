import Foundation

/// Maps a wall-clock range onto the segments that cover it, as one gapless playback timeline.
///
/// Gaps where recording was paused are skipped, so playback time and wall-clock time drift
/// apart; use `time(for:)` and `date(for:)` to convert between them.
public struct PlaybackTimeline: Sendable, Equatable {
    public struct Piece: Sendable, Equatable {
        public var segment: Segment
        /// Where this piece starts inside the segment file, in seconds.
        public var offsetInSegment: TimeInterval
        public var duration: TimeInterval
        /// Where this piece starts on the playback timeline, in seconds.
        public var playbackStart: TimeInterval

        public var wallStart: Date { segment.start.addingTimeInterval(offsetInSegment) }
        public var wallEnd: Date { wallStart.addingTimeInterval(duration) }
    }

    public private(set) var pieces: [Piece] = []

    public init(segments: [Segment], start: Date, end: Date) {
        var cursor: TimeInterval = 0
        for segment in segments.sorted(by: { $0.start < $1.start }) where segment.overlaps(start, end) {
            let from = max(start, segment.start)
            let to = min(end, segment.end)
            let duration = to.timeIntervalSince(from)
            guard duration > 0 else { continue }
            pieces.append(Piece(segment: segment,
                                offsetInSegment: from.timeIntervalSince(segment.start),
                                duration: duration,
                                playbackStart: cursor))
            cursor += duration
        }
    }

    public var duration: TimeInterval {
        pieces.last.map { $0.playbackStart + $0.duration } ?? 0
    }

    public var isEmpty: Bool { pieces.isEmpty }

    /// The wall-clock moment the last recorded footage ends.
    public var footageEnd: Date? { pieces.last?.wallEnd }

    /// Whether `date` falls inside recorded footage (not in a gap or past either end).
    public func contains(_ date: Date) -> Bool {
        pieces.contains { $0.wallStart <= date && date <= $0.wallEnd }
    }

    /// Playback time for a wall-clock date. Dates inside a recording gap snap to the next
    /// recorded moment; dates outside the timeline clamp to its ends.
    public func time(for date: Date) -> TimeInterval {
        for piece in pieces {
            if date < piece.wallStart { return piece.playbackStart }
            if date <= piece.wallEnd { return piece.playbackStart + date.timeIntervalSince(piece.wallStart) }
        }
        return duration
    }

    public func date(for time: TimeInterval) -> Date? {
        guard let piece = pieces.last(where: { $0.playbackStart <= time }) ?? pieces.first else { return nil }
        let offset = min(max(time - piece.playbackStart, 0), piece.duration)
        return piece.wallStart.addingTimeInterval(offset)
    }
}
