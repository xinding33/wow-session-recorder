import Foundation
import RecorderCore
import os

/// Follows the newest `WoWCombatLog-*.txt` in the Logs folder and emits parsed events.
///
/// WoW buffers log writes, so events arrive a few seconds late. That's fine: footage is
/// recorded continuously and events are matched to it by timestamp, not arrival time.
final class CombatLogTailer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SessionRecorder.CombatLogTailer", qos: .utility)
    private let log = Logger(subsystem: "SessionRecorder", category: "CombatLog")
    private let logsDirectory: URL
    private let onEntries: @Sendable ([CombatLogEntry]) -> Void
    private let onNewFile: @Sendable () -> Void
    private let onWrite: @Sendable (Date) -> Void
    private let onSeedZone: @Sendable (CombatLogEntry) -> Void

    private var timer: DispatchSourceTimer?
    private var currentFile: URL?
    private var offset: UInt64 = 0
    private var buffer = LineBuffer()
    /// Caps how much is read per poll so a huge backlog can't stall the queue.
    private let maxReadPerPoll = 16 << 20

    init(logsDirectory: URL,
         onEntries: @escaping @Sendable ([CombatLogEntry]) -> Void,
         onNewFile: @escaping @Sendable () -> Void,
         onWrite: @escaping @Sendable (Date) -> Void,
         onSeedZone: @escaping @Sendable (CombatLogEntry) -> Void) {
        self.logsDirectory = logsDirectory
        self.onEntries = onEntries
        self.onNewFile = onNewFile
        self.onWrite = onWrite
        self.onSeedZone = onSeedZone
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard let (url, size, modified) = newestLog() else { return }

        if url != currentFile {
            let isFirstFile = currentFile == nil
            currentFile = url
            // On launch, skip history: there's no footage for it. A file that appears while
            // we're running is brand new, so read it from the top.
            offset = isFirstFile ? size : 0
            buffer.reset(startOffset: offset)
            if isFirstFile, Date().timeIntervalSince(modified) < 10 * 60, let zone = lastZoneChange(in: url, size: size) {
                onSeedZone(zone)
            }
            if !isFirstFile {
                log.info("Following new combat log \(url.lastPathComponent, privacy: .public)")
                onNewFile()
            }
        }

        if size < offset {
            offset = 0
            buffer.reset(startOffset: 0)
        }
        guard size > offset else { return }
        onWrite(modified)

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            let count = Int(min(size - offset, UInt64(maxReadPerPoll)))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else { return }
            offset += UInt64(data.count)
            let fileName = url.lastPathComponent
            let entries = buffer.appendWithOffsets(data).compactMap { line, lineOffset in
                CombatLogParser.parse(line: line, position: LogPosition(fileName: fileName, offset: lineOffset))
            }
            if !entries.isEmpty {
                onEntries(entries)
            }
        } catch {
            log.error("Couldn't read combat log: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Finds where the player is from the tail of a log that was already being written.
    private func lastZoneChange(in url: URL, size: UInt64) -> CombatLogEntry? {
        let tail: UInt64 = 8 << 20
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let start = size > tail ? size - tail : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return nil }
        var lines = LineBuffer()
        return lines.append(data).reversed().lazy
            .filter { $0.contains("  ZONE_CHANGE,") }
            .compactMap { CombatLogParser.parse(line: $0) }
            .first
    }

    private func newestLog() -> (URL, UInt64, Date)? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: logsDirectory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("WoWCombatLog") && $0.pathExtension == "txt" }
            .compactMap { url -> (URL, UInt64, Date)? in
                guard let values = try? url.resourceValues(forKeys: keys),
                      let size = values.fileSize,
                      let modified = values.contentModificationDate
                else { return nil }
                return (url, UInt64(size), modified)
            }
            .max { $0.2 < $1.2 }
    }
}
