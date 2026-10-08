import AVFoundation
import Observation
import RecorderCore
import os

/// What to play: a wall-clock range plus the markers to show on its timeline. Playback adds a
/// little footage either side so you see the run-in to a pull.
struct PlaybackItem: Equatable {
    var title: String
    var start: Date
    var end: Date
    var markers: [Marker]
    /// Where playback should open, e.g. just before a bookmark. `nil` opens at the start.
    var focus: Date?
    /// The library activity being played; `nil` for a footage session.
    var activityID: Activity.ID?

    /// An activity still in progress has no end yet; it grows as segments are written.
    var isLive: Bool { end == .distantFuture }

    /// Stays the same while a live activity gains markers or ends, so playback keeps its place.
    var identity: String { activityID?.uuidString ?? "\(start.timeIntervalSince1970)" }
}

/// Stitches segment files into one seamless `AVComposition` and drives playback.
@MainActor
@Observable
final class PlaybackController {
    struct TimedMarker: Identifiable, Equatable {
        var marker: Marker
        var time: Double
        var id: UUID { marker.id }
    }

    let player = AVPlayer()
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var markers: [TimedMarker] = []
    /// Markers whose footage hasn't been written yet (the newest segment is still recording).
    private(set) var pendingMarkerCount = 0
    /// Seconds at the end of the item that aren't playable yet.
    private(set) var pendingSeconds: Double = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isExporting = false
    /// Trim points, in playback seconds. Either can be unset: the selection then runs from the
    /// start or to the end.
    private(set) var inPoint: Double?
    private(set) var outPoint: Double?
    /// Marker types not shown on the timeline or in the list.
    var hiddenCategories: Set<MarkerCategory> = []
    var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        }
    }

    private var composition: AVMutableComposition?
    private var timeline: PlaybackTimeline?
    private var loadedIdentity: String?
    private var timeObserver: Any?
    private let log = Logger(subsystem: "SessionRecorder", category: "Playback")

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
    }

    /// Builds the composition for `item`. Reloading the same item (a new segment finished, or a
    /// live activity gained markers) keeps the playback position and trim points.
    func load(_ item: PlaybackItem, segments: [Segment]) async {
        let keepPosition = item.identity == loadedIdentity
        loadedIdentity = item.identity
        let resumeDate = keepPosition ? timeline?.date(for: currentTime) : nil
        // Trim points are kept as real-world times: a reload can insert footage before them.
        let inDate = keepPosition ? inPoint.flatMap { timeline?.date(for: $0) } : nil
        let outDate = keepPosition ? outPoint.flatMap { timeline?.date(for: $0) } : nil
        inPoint = nil
        outPoint = nil
        let wasPlaying = keepPosition && player.rate != 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        isLoading = !keepPosition
        errorMessage = nil
        defer { isLoading = false }

        let requestedEnd = item.end.addingTimeInterval(AppSettings.paddingAfter)
        let timeline = PlaybackTimeline(
            segments: segments,
            start: item.start.addingTimeInterval(-AppSettings.paddingBefore),
            end: requestedEnd)
        guard !timeline.isEmpty else {
            errorMessage = "No footage for this activity yet. The newest minute appears once it finishes recording; otherwise it may have been cleaned up, or recording wasn't running."
            markers = []
            duration = 0
            pendingMarkerCount = item.markers.count
            pendingSeconds = 0
            return
        }

        let loaded = await Self.loadSegments(timeline.pieces.map(\.segment.url))

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero

        for (index, piece) in timeline.pieces.enumerated() {
            let planned = CMTime(seconds: piece.duration, preferredTimescale: 600)
            let range = CMTimeRange(start: CMTime(seconds: piece.offsetInSegment, preferredTimescale: 600), duration: planned)
            do {
                guard let segment = loaded[index] else { throw CocoaError(.fileReadCorruptFile) }
                // Clamp to the real file length; pad any shortfall so marker times stay aligned.
                let available = CMTimeRange(start: .zero, duration: segment.duration).intersection(range)
                if let video = segment.video, available.duration > .zero {
                    try videoTrack.insertTimeRange(available, of: video, at: cursor)
                    if let audio = segment.audio {
                        if audioTrack == nil {
                            audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                            if cursor > .zero { audioTrack?.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: cursor)) }
                        }
                        try audioTrack?.insertTimeRange(available, of: audio, at: cursor)
                    }
                }
                let inserted = max(available.duration, .zero)
                if inserted < planned {
                    composition.insertEmptyTimeRange(CMTimeRange(start: cursor + inserted, duration: planned - inserted))
                }
            } catch {
                log.error("Skipping \(piece.segment.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                composition.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: planned))
            }
            cursor = cursor + planned
        }

        self.composition = composition
        self.timeline = timeline
        duration = timeline.duration
        // Only show markers that have footage; others would be pinned to the wrong place.
        markers = item.markers
            .filter { timeline.contains($0.date) }
            .map { TimedMarker(marker: $0, time: timeline.time(for: $0.date)) }
            .sorted { $0.time < $1.time }
        pendingMarkerCount = item.markers.count - markers.count
        pendingSeconds = item.isLive ? 0 : max(0, requestedEnd.timeIntervalSince(timeline.footageEnd ?? requestedEnd))
        inPoint = inDate.map { timeline.time(for: $0) }
        outPoint = outDate.map { timeline.time(for: $0) }

        let playerItem = AVPlayerItem(asset: composition)
        player.replaceCurrentItem(with: playerItem)
        player.defaultRate = rate
        if let date = resumeDate ?? item.focus {
            seek(to: timeline.time(for: date))
        } else {
            seek(to: 0)
        }
        if wasPlaying { player.playImmediately(atRate: rate) }
    }

    /// The real-world time of the frame on screen.
    var currentWallClock: Date? {
        timeline?.date(for: currentTime)
    }

    var visibleMarkers: [TimedMarker] {
        markers.filter { !hiddenCategories.contains($0.marker.kind.category) }
    }

    /// Marker types this item has, for the show/hide menu.
    var markerCategories: [MarkerCategory] {
        let present = Set(markers.map(\.marker.kind.category))
        return MarkerCategory.allCases.filter(present.contains)
    }

    // MARK: - Trimming

    /// The selected range in playback seconds, if a trim point is set.
    var selection: ClosedRange<Double>? {
        guard inPoint != nil || outPoint != nil else { return nil }
        let start = inPoint ?? 0, end = outPoint ?? duration
        return end > start ? start...end : nil
    }

    /// The selection as real-world times, for saving it as a clip.
    var selectionDates: (start: Date, end: Date)? {
        guard let selection, let start = timeline?.date(for: selection.lowerBound),
              let end = timeline?.date(for: selection.upperBound) else { return nil }
        return (start, end)
    }

    func setInPoint() {
        inPoint = currentTime
        if let outPoint, outPoint <= currentTime { self.outPoint = nil }
    }

    func setOutPoint() {
        outPoint = currentTime
        if let inPoint, inPoint >= currentTime { self.inPoint = nil }
    }

    func clearSelection() {
        inPoint = nil
        outPoint = nil
    }

    private struct LoadedSegment: @unchecked Sendable {
        /// Held so the tracks stay valid; an `AVAssetTrack` only weakly references its asset.
        let asset: AVURLAsset
        let duration: CMTime
        let video: AVAssetTrack?
        let audio: AVAssetTrack?
    }

    /// Loads segment metadata concurrently. A 3-hour session is ~180 files, which took seconds
    /// to open one by one.
    private nonisolated static func loadSegments(_ urls: [URL]) async -> [Int: LoadedSegment] {
        await withTaskGroup(of: (Int, LoadedSegment?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    let asset = AVURLAsset(url: url)
                    do {
                        async let duration = asset.load(.duration)
                        async let video = asset.loadTracks(withMediaType: .video)
                        async let audio = asset.loadTracks(withMediaType: .audio)
                        return (index, LoadedSegment(asset: asset, duration: try await duration,
                                                     video: try await video.first, audio: try await audio.first))
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var results: [Int: LoadedSegment] = [:]
            for await (index, segment) in group {
                results[index] = segment
            }
            return results
        }
    }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), max(duration - 0.05, 0))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Seconds of lead-up shown before a marker when jumping to it.
    static let markerLeadIn: Double = 2

    func jump(to marker: TimedMarker) {
        seek(to: marker.time - Self.markerLeadIn)
        player.playImmediately(atRate: rate)
    }

    /// Seeks to a real-world moment, e.g. a hit in a death recap.
    func seek(to date: Date, leadIn: Double = 0) {
        guard let timeline, timeline.contains(date) else { return }
        seek(to: timeline.time(for: date) - leadIn)
    }

    func jumpToNextMarker() {
        if let next = visibleMarkers.first(where: { $0.time - Self.markerLeadIn > currentTime + 0.5 }) { jump(to: next) }
    }

    func jumpToPreviousMarker() {
        if let previous = visibleMarkers.last(where: { $0.time - Self.markerLeadIn < currentTime - 1.5 }) { jump(to: previous) }
    }

    func togglePlayback() {
        if player.rate == 0 { player.playImmediately(atRate: rate) } else { player.pause() }
    }

    func stop() {
        player.pause()
    }

    /// Exports the whole item, or just `range` (playback seconds), without re-encoding.
    func export(to url: URL, range: ClosedRange<Double>? = nil) async throws {
        guard let composition else { return }
        isExporting = true
        defer { isExporting = false }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let range {
            session.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                            end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        }
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: .mp4)
    }
}
