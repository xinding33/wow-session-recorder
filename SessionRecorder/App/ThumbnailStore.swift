import AVFoundation
import AppKit
import ImageIO
import RecorderCore
import UniformTypeIdentifiers
import os

/// Library thumbnails: one small JPEG per finished activity, cached next to the footage.
///
/// Stills are made lazily as rows scroll into view, and only while this app is frontmost, so
/// nothing is decoded while you're playing. They're made one at a time at background priority,
/// from the nearest keyframe (one every 2 s), so each costs a single small hardware decode.
@MainActor
final class ThumbnailStore {
    /// Big enough for a sharp row on a Retina screen.
    private nonisolated static let maxSize = CGSize(width: 320, height: 180)

    private let cache = NSCache<NSUUID, NSImage>()
    /// Activities with no footage to take a still from, and how much footage there was then,
    /// so rows don't retry until new footage arrives.
    private var unavailable: [UUID: Int] = [:]
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let log = Logger(subsystem: "SessionRecorder", category: "Thumbnails")

    init() {
        cache.countLimit = 500
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.startNext() }
        }
    }

    /// The activity's thumbnail, from memory, disk, or (when this app is frontmost) its footage.
    /// `segments` is the footage around the activity; `footageCount` changes when footage is
    /// added or removed.
    func image(for activity: Activity, segments: [Segment], footageCount: Int, in directory: URL) async -> NSImage? {
        guard !activity.isInProgress else { return nil }
        let key = activity.id as NSUUID
        if let image = cache.object(forKey: key) { return image }
        let url = directory.appending(path: Thumbnails.fileName(for: activity.id))
        if let image = await Self.load(url) {
            cache.setObject(image, forKey: key)
            return image
        }
        if unavailable[activity.id] == footageCount { return nil }
        guard let source = Thumbnails.source(for: activity, segments: segments) else {
            unavailable[activity.id] = footageCount
            return nil
        }

        await waitForTurn()
        defer { finishTurn() }
        // Scrolled away while waiting, or another row made it meanwhile.
        guard !Task.isCancelled else { return nil }
        if let image = cache.object(forKey: key) { return image }

        let started = ContinuousClock.now
        do {
            let image = try await Self.generate(from: source.url, at: source.time, writingTo: url)
            log.debug("Made thumbnail in \(started.duration(to: .now), privacy: .public)")
            cache.setObject(image, forKey: key)
            return image
        } catch {
            log.error("Thumbnail for \(activity.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            unavailable[activity.id] = footageCount
            return nil
        }
    }

    /// Deletes the thumbnails of deleted or expired activities.
    func remove(_ ids: some Sequence<UUID>, in directory: URL) {
        for id in ids {
            cache.removeObject(forKey: id as NSUUID)
            unavailable[id] = nil
            try? FileManager.default.removeItem(at: directory.appending(path: Thumbnails.fileName(for: id)))
        }
    }

    /// Deletes thumbnails left behind by activities removed some other way (e.g. a crash
    /// before the library was saved).
    nonisolated func removeOrphans(keeping ids: Set<UUID>, in directory: URL) {
        Task.detached(priority: .background) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in Thumbnails.orphans(fileNames: names, keeping: ids) {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
    }

    // MARK: - One at a time, while frontmost

    private func waitForTurn() async {
        if !isBusy, NSApp.isActive {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func finishTurn() {
        isBusy = false
        startNext()
    }

    /// Hands the turn to the next waiting row. Waits while another app (e.g. WoW) is frontmost.
    private func startNext() {
        guard !isBusy, NSApp.isActive, !waiting.isEmpty else { return }
        isBusy = true
        waiting.removeFirst().resume()
    }

    // MARK: - Off the main thread

    private nonisolated static func load(_ url: URL) async -> NSImage? {
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }.value
        return image.map { NSImage(cgImage: $0, size: .zero) }
    }

    private nonisolated static func generate(from segment: URL, at seconds: TimeInterval, writingTo url: URL) async throws -> NSImage {
        let image = try await Task.detached(priority: .background) {
            let asset = AVURLAsset(url: segment)
            // Video can stop before the segment does (no frames while WoW was hidden), and asking
            // past its end fails.
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let videoEnd = try await video.load(.timeRange).end.seconds
            let seconds = min(seconds, max(0, videoEnd - 0.5))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = maxSize
            generator.appliesPreferredTrackTransform = true
            // Any frame within 2 s will do, so it can use a keyframe and skip decoding a run of frames.
            let tolerance = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            return image
        }.value
        return NSImage(cgImage: image, size: .zero)
    }
}
