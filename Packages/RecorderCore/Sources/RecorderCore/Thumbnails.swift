import Foundation

/// Where library thumbnails come from and how they're cached.
///
/// Each finished activity gets one still, saved as `Thumbnails/<activity id>.jpg` next to the
/// footage. A thumbnail outlives its footage, and is deleted with its activity.
public enum Thumbnails {
    /// How far into the action the still is taken.
    public static let leadIn: TimeInterval = 5

    public static func fileName(for id: UUID) -> String {
        "\(id.uuidString).jpg"
    }

    public static func activityID(fromFileName name: String) -> UUID? {
        guard name.hasSuffix(".jpg") else { return nil }
        return UUID(uuidString: String(name.dropLast(4)))
    }

    /// Cached files whose activity is gone.
    public static func orphans(fileNames: [String], keeping ids: Set<UUID>) -> [String] {
        fileNames.filter { name in
            activityID(fromFileName: name).map { !ids.contains($0) } ?? false
        }
    }

    /// The moment to show: a few seconds into the fight, or just before a bookmark. Keys and
    /// delves show their first boss, which says more than the entrance. `nil` while in progress.
    public static func moment(for activity: Activity) -> Date? {
        guard let end = activity.end else { return nil }
        let anchor: Date
        switch activity.kind {
        case .mythicPlus, .delve:
            let pull = activity.markers.first { $0.kind == .bossPull && $0.date >= activity.start && $0.date < end }
            anchor = (pull?.date ?? activity.start) + leadIn
        case .clip:
            if let bookmark = activity.markers.first(where: { $0.kind == .bookmark }) {
                anchor = bookmark.date - 3
            } else {
                anchor = activity.start + leadIn
            }
        default:
            anchor = activity.start + leadIn
        }
        // Activities too short for that show their middle instead.
        return anchor < end ? max(anchor, activity.start) : activity.start + end.timeIntervalSince(activity.start) / 2
    }

    /// The segment file and the time within it to take the still from. Falls back to the first
    /// footage inside the activity when recording was paused at the chosen moment.
    public static func source(for activity: Activity, segments: [Segment]) -> (url: URL, time: TimeInterval)? {
        guard let moment = moment(for: activity), let end = activity.end else { return nil }
        if let segment = segments.first(where: { $0.start <= moment && moment < $0.end }) {
            return (segment.url, moment.timeIntervalSince(segment.start))
        }
        guard let segment = segments.first(where: { $0.overlaps(activity.start, end) }) else { return nil }
        let from = max(activity.start, segment.start)
        let to = min(end, segment.end)
        return (segment.url, from.timeIntervalSince(segment.start) + min(1, to.timeIntervalSince(from) / 2))
    }
}
