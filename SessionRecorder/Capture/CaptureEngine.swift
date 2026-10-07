import AppKit
import ScreenCaptureKit
import RecorderCore
import os

enum CaptureQuality: String, CaseIterable, Identifiable, Sendable {
    case p1080
    case p1440
    case native

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .native: "Native"
        }
    }

    private var maxHeight: CGFloat? {
        switch self {
        case .p1080: 1080
        case .p1440: 1440
        case .native: nil
        }
    }

    /// Output size for a source of `size` pixels: scaled to fit, aspect kept, even dimensions.
    func outputSize(for size: CGSize) -> CGSize {
        var scale: CGFloat = 1
        if let maxHeight, size.height > maxHeight {
            scale = maxHeight / size.height
        }
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// HEVC bitrate that looks clean for fast-moving game footage.
    static func bitrate(for size: CGSize, fps: Int) -> Int {
        let bitsPerPixel = 0.08
        let raw = Double(size.width * size.height) * Double(fps) * bitsPerPixel
        return Int(min(max(raw, 4_000_000), 50_000_000))
    }
}

enum CaptureError: LocalizedError {
    case gameNotRunning
    case noGameWindow

    var errorDescription: String? {
        switch self {
        case .gameNotRunning: "World of Warcraft isn't running."
        case .noGameWindow: "Couldn't find the World of Warcraft window."
        }
    }
}

struct CaptureTarget: Equatable {
    var windowFrame: CGRect
    var displayID: CGDirectDisplayID

    /// Same window placement, ignoring sub-point jitter.
    func matches(_ other: CaptureTarget) -> Bool {
        displayID == other.displayID
            && abs(windowFrame.minX - other.windowFrame.minX) < 1
            && abs(windowFrame.minY - other.windowFrame.minY) < 1
            && abs(windowFrame.width - other.windowFrame.width) < 1
            && abs(windowFrame.height - other.windowFrame.height) < 1
    }
}

/// Captures the WoW window with ScreenCaptureKit and hands frames to a `SegmentWriter`.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: "SessionRecorder", category: "Capture")
    private var stream: SCStream?
    private var writer: SegmentWriter?
    private(set) var target: CaptureTarget?

    /// Called on an arbitrary queue when capture stops unexpectedly.
    var onUnexpectedStop: (@Sendable (Error) -> Void)?

    var isRunning: Bool { stream != nil }

    func start(bundleID: String, quality: CaptureQuality, fps: Int, captureAudio: Bool,
               directory: URL, onSegment: @escaping @Sendable (Segment) -> Void) async throws {
        let (app, window, display) = try await Self.findGame(bundleID: bundleID)
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

        // Crop to the game window so windowed mode doesn't record the whole desktop.
        let displayBounds = CGRect(origin: .zero, size: display.frame.size)
        var sourceRect = window.frame
            .offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            .intersection(displayBounds)
        if sourceRect.isNull || sourceRect.width < 100 { sourceRect = displayBounds }

        let pixelScale = CGFloat(filter.pointPixelScale)
        let nativeSize = CGSize(width: sourceRect.width * pixelScale, height: sourceRect.height * pixelScale)
        let outputSize = quality.outputSize(for: nativeSize)

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(outputSize.width)
        config.height = Int(outputSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = captureAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        let settings = EncoderSettings(
            width: config.width, height: config.height, fps: fps,
            bitrate: CaptureQuality.bitrate(for: outputSize, fps: fps), captureAudio: captureAudio)
        let writer = SegmentWriter(directory: directory, settings: settings, onSegment: onSegment)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writer.queue)
        if captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writer.queue)
        }

        self.writer = writer
        self.stream = stream
        // Record the placement the same way it's checked later, so the two always compare equal.
        target = Self.currentTarget(processID: app.processID)
            ?? CaptureTarget(windowFrame: window.frame, displayID: display.displayID)
        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            self.writer = nil
            target = nil
            throw error
        }
        log.info("Capturing \(config.width)x\(config.height)@\(fps) at \(settings.bitrate / 1_000_000) Mbps")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        target = nil
        try? await stream.stopCapture()
        await finishWriter()
    }

    /// The game window's current position, to detect fullscreen toggles and moves.
    ///
    /// Uses CGWindowList, which is far cheaper than a ScreenCaptureKit content query and fine to
    /// call every few seconds during play. `nil` when the window isn't on screen.
    static func currentTarget(processID: pid_t) -> CaptureTarget? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let frame = windows
            .compactMap { info -> CGRect? in
                guard (info[kCGWindowOwnerPID as String] as? pid_t) == processID,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds),
                      rect.width > 200
                else { return nil }
                return rect
            }
            .max { $0.width * $0.height < $1.width * $1.height }
        guard let frame else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &display, &count)
        return CaptureTarget(windowFrame: frame, displayID: count > 0 ? display : 0)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid, let writer else { return }
        switch type {
        case .screen:
            // Idle frames (nothing changed on screen) carry no image.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete
            else { return }
            writer.appendVideo(sample)
        case .audio:
            writer.appendAudio(sample)
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Capture stopped: \(error.localizedDescription, privacy: .public)")
        self.stream = nil
        target = nil
        Task {
            await finishWriter()
            onUnexpectedStop?(error)
        }
    }

    // MARK: - Private

    private func finishWriter() async {
        guard let writer else { return }
        self.writer = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.queue.async {
                writer.finish { continuation.resume() }
            }
        }
    }

    private static func findGame(bundleID: String) async throws -> (SCRunningApplication, SCWindow, SCDisplay) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw CaptureError.gameNotRunning
        }
        let window = content.windows
            .filter { $0.owningApplication?.processID == app.processID && $0.windowLayer == 0 && $0.frame.width > 200 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let window else { throw CaptureError.noGameWindow }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
            throw CaptureError.noGameWindow
        }
        return (app, window, display)
    }
}
