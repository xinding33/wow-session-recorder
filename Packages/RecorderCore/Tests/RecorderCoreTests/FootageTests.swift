import Foundation
import Testing
@testable import RecorderCore

struct FootageTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let dir = URL(fileURLWithPath: "/tmp/segments")

    private func segment(_ from: TimeInterval, _ to: TimeInterval) -> Segment {
        let start = t0 + from, end = t0 + to
        return Segment(url: dir.appending(path: SegmentNaming.finalName(start: start, end: end)), start: start, end: end)
    }

    @Test func segmentNamesRoundTrip() throws {
        let original = segment(0, 60.5)
        let parsed = try #require(SegmentNaming.parse(original.url))
        #expect(parsed == original)
        #expect(SegmentNaming.parse(dir.appending(path: SegmentNaming.partialName(start: t0))) == nil)
        #expect(SegmentNaming.parse(dir.appending(path: "notes.txt")) == nil)
    }

    @Test func groupsSegmentsIntoSessions() {
        let segments = [segment(0, 60), segment(60, 120), segment(500, 560)]
        let sessions = SegmentIndex.sessions(segments)
        #expect(sessions.count == 2)
        #expect(sessions[0].segments.count == 2)
        #expect(sessions[1].start == t0 + 500)
    }

    @Test func retentionKeepsActivityFootageAndRecentFootage() {
        let segments = [segment(0, 60), segment(60, 120), segment(120, 180), segment(180, 240)]
        let activity = Activity(kind: .raidEncounter, title: "Boss", start: t0 + 70, end: t0 + 100)
        let policy = RetentionPolicy(keepUnmarkedFootage: 3600, paddingBefore: 10, paddingAfter: 5)

        // Two hours later, only the segment holding the activity survives.
        let doomed = policy.segmentsToDelete(segments, keeping: [activity], now: t0 + 7200)
        #expect(doomed.map(\.start) == [t0, t0 + 120, t0 + 180])

        // Shortly after, everything is still inside the unmarked window.
        #expect(policy.segmentsToDelete(segments, keeping: [], now: t0 + 600).isEmpty)
    }

    @Test func retentionPaddingCanPullInNeighbouringSegments() {
        let segments = [segment(0, 60), segment(60, 120)]
        let activity = Activity(kind: .raidEncounter, title: "Boss", start: t0 + 65, end: t0 + 100)
        let policy = RetentionPolicy(keepUnmarkedFootage: 0, paddingBefore: 10, paddingAfter: 0)
        #expect(policy.segmentsToDelete(segments, keeping: [activity], now: t0 + 7200).isEmpty)
    }

    @Test func expiredActivitiesSkipFavoritesAndOpenActivities() {
        let old = Activity(kind: .clip, title: "Old", start: t0, end: t0 + 10)
        let fav = Activity(kind: .clip, title: "Fav", start: t0, end: t0 + 10, isFavorite: true)
        let open = Activity(kind: .clip, title: "Open", start: t0)
        let policy = RetentionPolicy(keepActivities: 86400)
        let expired = policy.expiredActivities([old, fav, open], now: t0 + 2 * 86400)
        #expect(expired.map(\.title) == ["Old"])
    }

    @Test func playbackTimelineSkipsGaps() throws {
        // Recording paused between 120s and 300s.
        let segments = [segment(0, 60), segment(60, 120), segment(300, 360)]
        let timeline = PlaybackTimeline(segments: segments, start: t0 + 30, end: t0 + 330)

        #expect(timeline.pieces.count == 3)
        #expect(timeline.pieces[0].offsetInSegment == 30)
        #expect(timeline.duration == 30 + 60 + 30)
        #expect(timeline.time(for: t0 + 90) == 60)
        // A date inside the gap snaps to when recording resumed.
        #expect(timeline.time(for: t0 + 200) == 90)
        #expect(timeline.time(for: t0 + 310) == 100)
        #expect(try #require(timeline.date(for: 100)) == t0 + 310)
        #expect(timeline.time(for: t0) == 0)
        #expect(timeline.time(for: t0 + 10_000) == timeline.duration)

        #expect(timeline.contains(t0 + 90))
        #expect(!timeline.contains(t0 + 200))
        #expect(!timeline.contains(t0 + 340))
        #expect(timeline.footageEnd == t0 + 330)
    }

    @Test func playbackTimelineEndsWhereFootageEnds() {
        // The segment covering the end of the range hasn't been written yet.
        let timeline = PlaybackTimeline(segments: [segment(0, 60)], start: t0 + 30, end: t0 + 90)
        #expect(timeline.duration == 30)
        #expect(timeline.footageEnd == t0 + 60)
        #expect(!timeline.contains(t0 + 75))
    }
}
