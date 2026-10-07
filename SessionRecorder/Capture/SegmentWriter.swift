import AVFoundation
import CoreMedia
import RecorderCore
import os

struct EncoderSettings: Sendable, Equatable {
    var width: Int
    var height: Int
    var fps: Int
    var bitrate: Int
    var captureAudio: Bool
}

/// Converts sample-buffer timestamps (host clock) to wall-clock dates, so footage lines up
/// with combat log timestamps.
enum HostClock {
    static func date(for time: CMTime) -> Date {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        return Date().addingTimeInterval((time - now).seconds)
    }
}

/// Encodes captured frames into fixed-length HEVC segment files.
///
/// Each segment is written as `seg_<start>.partial.mp4` and renamed to its final
/// `seg_<start>_<end>.mp4` name once complete, so a crash loses at most one segment.
/// Every method must be called on `queue`.
final class SegmentWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "SessionRecorder.SegmentWriter", qos: .userInitiated)

    private final class Output: @unchecked Sendable {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput?
        let startTime: CMTime
        let startDate: Date
        let partialURL: URL
        var endTime: CMTime = .invalid
        /// Frames ScreenCaptureKit delivered for this segment.
        var framesReceived = 0
        /// Frames dropped because the encoder wasn't ready (the recorder falling behind).
        var framesDropped = 0

        init(writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?,
             startTime: CMTime, startDate: Date, partialURL: URL) {
            self.writer = writer
            self.video = video
            self.audio = audio
            self.startTime = startTime
            self.startDate = startDate
            self.partialURL = partialURL
        }
    }

    private let directory: URL
    private let settings: EncoderSettings
    private let segmentDuration: TimeInterval
    private let onSegment: @Sendable (Segment) -> Void
    private let log = Logger(subsystem: "SessionRecorder", category: "SegmentWriter")

    private var current: Output?
    /// The previous segment, kept open briefly so late audio for its tail can still land in it.
    private var closing: Output?
    private var lastVideoTime: CMTime = .invalid
    private let pending = DispatchGroup()

    init(directory: URL, settings: EncoderSettings, segmentDuration: TimeInterval = 60,
         onSegment: @escaping @Sendable (Segment) -> Void) {
        self.directory = directory
        self.settings = settings
        self.segmentDuration = segmentDuration
        self.onSegment = onSegment
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        let time = sample.presentationTimeStamp
        if let output = current, (time - output.startTime).seconds >= segmentDuration {
            rollOver(at: time)
        }
        if current == nil {
            current = makeOutput(startingAt: time)
        }
        guard let output = current else { return }
        guard output.writer.status == .writing else {
            log.error("Writer failed: \(String(describing: output.writer.error), privacy: .public)")
            output.writer.cancelWriting()
            try? FileManager.default.removeItem(at: output.partialURL)
            current = nil
            return
        }
        output.framesReceived += 1
        if output.video.isReadyForMoreMediaData {
            output.video.append(sample)
        } else {
            output.framesDropped += 1
        }
        lastVideoTime = time

        if let old = closing, (time - old.endTime).seconds > 0.5 {
            finalize(old)
            closing = nil
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        let time = sample.presentationTimeStamp
        if let old = closing, time < old.endTime {
            append(sample, to: old.audio, of: old)
        } else if let output = current, time >= output.startTime {
            append(sample, to: output.audio, of: output)
        }
    }

    /// Finishes all open segments. `completion` runs once every file is renamed.
    func finish(completion: @escaping @Sendable () -> Void) {
        if let old = closing {
            finalize(old)
            closing = nil
        }
        if let output = current {
            let frame = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
            output.endTime = lastVideoTime.isValid ? lastVideoTime + frame : output.startTime + frame
            output.video.markAsFinished()
            finalize(output)
            current = nil
        }
        pending.notify(queue: queue, execute: completion)
    }

    // MARK: - Private

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?, of output: Output) {
        guard let input, output.writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    private func rollOver(at time: CMTime) {
        guard let output = current else { return }
        if let old = closing { finalize(old) }
        output.endTime = time
        output.video.markAsFinished()
        closing = output
        current = nil
    }

    private func finalize(_ output: Output) {
        guard output.writer.status == .writing else {
            output.writer.cancelWriting()
            try? FileManager.default.removeItem(at: output.partialURL)
            return
        }
        output.audio?.markAsFinished()
        output.writer.endSession(atSourceTime: output.endTime)
        let seconds = (output.endTime - output.startTime).seconds
        let endDate = output.startDate.addingTimeInterval(seconds)
        // Received fps reflects what WoW rendered; drops are frames the recorder lost itself.
        let fps = Double(output.framesReceived) / max(seconds, 0.001)
        log.notice("Segment \(Int(seconds))s: \(output.framesReceived) frames (\(fps, format: .fixed(precision: 1)) fps), \(output.framesDropped) dropped by encoder")
        let finalURL = directory.appending(path: SegmentNaming.finalName(start: output.startDate, end: endDate))
        let onSegment = onSegment
        let log = log
        pending.enter()
        output.writer.finishWriting { [pending] in
            defer { pending.leave() }
            guard output.writer.status == .completed else {
                log.error("Segment failed: \(String(describing: output.writer.error), privacy: .public)")
                try? FileManager.default.removeItem(at: output.partialURL)
                return
            }
            do {
                try FileManager.default.moveItem(at: output.partialURL, to: finalURL)
                onSegment(Segment(url: finalURL, start: output.startDate, end: endDate))
            } catch {
                log.error("Couldn't rename segment: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func makeOutput(startingAt time: CMTime) -> Output? {
        let startDate = HostClock.date(for: time)
        let url = directory.appending(path: SegmentNaming.partialName(start: startDate))
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: settings.width,
                AVVideoHeightKey: settings.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: settings.bitrate,
                    AVVideoExpectedSourceFrameRateKey: settings.fps,
                    // A keyframe every 2s keeps seeking snappy.
                    AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ])
            video.expectsMediaDataInRealTime = true
            writer.add(video)

            var audio: AVAssetWriterInput?
            if settings.captureAudio {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 160_000,
                ])
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                audio = input
            }

            guard writer.startWriting() else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            writer.startSession(atSourceTime: time)
            return Output(writer: writer, video: video, audio: audio,
                          startTime: time, startDate: startDate, partialURL: url)
        } catch {
            log.error("Couldn't start segment: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
