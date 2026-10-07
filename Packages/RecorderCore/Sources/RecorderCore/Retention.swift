import Foundation

/// Decides what footage and which activities to clean up.
///
/// Footage is recorded continuously; anything not covered by an activity is only kept for a
/// short window so you can still scrub through a recent session. Activities themselves expire
/// after a longer window unless favorited.
public struct RetentionPolicy: Sendable, Equatable {
    /// How long footage outside any activity is kept. `nil` keeps it forever.
    public var keepUnmarkedFootage: TimeInterval?
    /// How long non-favorite activities are kept. `nil` keeps them forever.
    public var keepActivities: TimeInterval?
    /// Extra footage kept before each activity.
    public var paddingBefore: TimeInterval
    /// Extra footage kept after each activity.
    public var paddingAfter: TimeInterval

    public init(
        keepUnmarkedFootage: TimeInterval? = 24 * 3600,
        keepActivities: TimeInterval? = 30 * 24 * 3600,
        paddingBefore: TimeInterval = 10,
        paddingAfter: TimeInterval = 5
    ) {
        self.keepUnmarkedFootage = keepUnmarkedFootage
        self.keepActivities = keepActivities
        self.paddingBefore = paddingBefore
        self.paddingAfter = paddingAfter
    }

    /// Activities that have aged out.
    public func expiredActivities(_ activities: [Activity], now: Date) -> [Activity] {
        guard let keep = keepActivities else { return [] }
        return activities.filter { activity in
            guard !activity.isFavorite, let end = activity.end else { return false }
            return now.timeIntervalSince(end) > keep
        }
    }

    /// Segments no surviving activity needs and that are older than the unmarked window.
    public func segmentsToDelete(_ segments: [Segment], keeping activities: [Activity], now: Date) -> [Segment] {
        guard let keepUnmarked = keepUnmarkedFootage else { return [] }
        let ranges = activities.map { activity in
            (activity.start.addingTimeInterval(-paddingBefore),
             (activity.end ?? now).addingTimeInterval(paddingAfter))
        }
        return segments.filter { segment in
            guard now.timeIntervalSince(segment.end) > keepUnmarked else { return false }
            return !ranges.contains { segment.overlaps($0.0, $0.1) }
        }
    }
}
