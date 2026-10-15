import Foundation
import Testing
@testable import RecorderCore

/// Copying activities out of the combat log for uploading to Warcraft Logs.
struct CombatLogSplitTests {
    private let header = "5/20/2026 13:31:34.075-7  COMBAT_LOG_VERSION,22,ADVANCED_LOG_ENABLED,1,BUILD_VERSION,12.0.5,PROJECT_ID,1"

    /// A Logs folder with one file per entry, and where each of its lines starts.
    private func logs(_ files: [String: [String]]) throws -> (folder: URL, offsets: [String: [UInt64]]) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var offsets: [String: [UInt64]] = [:]
        for (name, lines) in files {
            var offset: UInt64 = 0
            offsets[name] = lines.map { line in
                defer { offset += UInt64(line.utf8.count + 2) }
                return offset
            }
            try lines.map { $0 + "\r\n" }.joined().write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        return (folder, offsets)
    }

    private func activity(_ title: String, start: TimeInterval, log: LogRange?, ended: Bool = true) -> Activity {
        var activity = Activity(kind: .mythicPlus, title: title, start: Date(timeIntervalSince1970: start),
                                end: ended ? Date(timeIntervalSince1970: start + 60) : nil, result: ended ? .completed : .inProgress)
        activity.log = log
        return activity
    }

    private func split(_ activities: [Activity], from folder: URL) throws -> [String] {
        let destination = folder.appending(path: "Split.txt")
        try CombatLogSplit.write(try CombatLogSplit.ranges(for: activities), from: folder, to: destination)
        return try String(contentsOf: destination, encoding: .utf8).components(separatedBy: "\r\n").dropLast()
    }

    @Test func copiesTheActivityAfterTheVersionHeader() throws {
        let lines = [header, "zone", "start", "fight", "end", "after"]
        let (folder, offsets) = try logs(["a.txt": lines])
        let o = try #require(offsets["a.txt"])
        let key = activity("Key", start: 0, log: LogRange(fileName: "a.txt", startOffset: o[2], endOffset: o[4]))
        // The end offset is where the ending line starts, so that line is kept whole.
        #expect(try split([key], from: folder) == [header, "start", "fight", "end"])
    }

    @Test func anActivityThatEndedInAnotherLogRunsToTheEndOfItsOwn() throws {
        let (folder, offsets) = try logs(["a.txt": [header, "before", "start", "fight"]])
        let o = try #require(offsets["a.txt"])
        let key = activity("Key", start: 0, log: LogRange(fileName: "a.txt", startOffset: o[2]))
        #expect(try split([key], from: folder) == [header, "start", "fight"])
    }

    @Test func mergesOverlapsAndHeadsEachLog() throws {
        let otherHeader = header.replacingOccurrences(of: "13:31:34", with: "22:00:00")
        let (folder, offsets) = try logs([
            "a.txt": [header, "pull 1", "end 1", "trash", "pull 2", "end 2"],
            "b.txt": [otherHeader, "pull 3", "end 3"],
        ])
        let a = try #require(offsets["a.txt"]), b = try #require(offsets["b.txt"])
        let first = activity("Pull 1", start: 0, log: LogRange(fileName: "a.txt", startOffset: a[1], endOffset: a[2]))
        let clip = activity("Pull 1 (clip)", start: 10, log: first.log)
        let second = activity("Pull 2", start: 100, log: LogRange(fileName: "a.txt", startOffset: a[4], endOffset: a[5]))
        let third = activity("Pull 3", start: 200, log: LogRange(fileName: "b.txt", startOffset: b[1], endOffset: b[2]))

        #expect(try CombatLogSplit.ranges(for: [third, clip, second, first]).count == 3)
        #expect(try split([third, clip, second, first], from: folder)
                == [header, "pull 1", "end 1", "pull 2", "end 2", otherHeader, "pull 3", "end 3"])
    }

    @Test func aRangeWithoutAnEndSwallowsLaterOnesInTheSameLog() throws {
        let unended = LogRange(fileName: "a.txt", startOffset: 10)
        let later = LogRange(fileName: "a.txt", startOffset: 50, endOffset: 80)
        let ranges = try CombatLogSplit.ranges(for: [activity("A", start: 0, log: unended), activity("B", start: 5, log: later)])
        #expect(ranges == [unended])
    }

    @Test func mergesInLogOrderNotTimeOrder() throws {
        // A clip from the padding after A starts after B, but comes first in the log.
        let a = LogRange(fileName: "a.txt", startOffset: 100, endOffset: 200)
        let b = activity("B", start: 62, log: LogRange(fileName: "a.txt", startOffset: 300, endOffset: 400))
        var clip = activity("A (clip)", start: 63, log: a)
        clip.kind = .clip
        #expect(try CombatLogSplit.ranges(for: [b, clip]) == [a, b.log])
    }

    @Test func aClipSavedMidKeyEndsWhereItsKeyDid() throws {
        var key = activity("Key", start: 0, log: LogRange(fileName: "a.txt", startOffset: 100, endOffset: 900))
        // The clip copied the key's range before the key ended.
        var clip = key.clip(from: Date(timeIntervalSince1970: 10), to: Date(timeIntervalSince1970: 20))
        clip.log?.endOffset = nil
        #expect(try CombatLogSplit.ranges(for: [clip], in: [key, clip]) == [key.log])

        #expect(throws: CombatLogSplit.SplitError.endUnknown(title: clip.title)) {
            try CombatLogSplit.ranges(for: [clip], in: [clip])
        }
        key.end = nil
        #expect(throws: CombatLogSplit.SplitError.inProgress(title: "Key")) {
            try CombatLogSplit.ranges(for: [clip], in: [key, clip])
        }
    }

    @Test func savingAgainReplacesTheFile() throws {
        let (folder, offsets) = try logs(["a.txt": [header, "one", "two"]])
        let o = try #require(offsets["a.txt"])
        #expect(try split([activity("A", start: 0, log: LogRange(fileName: "a.txt", startOffset: o[1], endOffset: o[1]))],
                          from: folder) == [header, "one"])
        #expect(try split([activity("A", start: 0, log: LogRange(fileName: "a.txt", startOffset: o[1], endOffset: o[2]))],
                          from: folder) == [header, "one", "two"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)
    }

    @Test func refusesWhatItCantCopy() throws {
        let (folder, _) = try logs(["a.txt": [header]])
        #expect(throws: CombatLogSplit.SplitError.inProgress(title: "Live")) {
            try CombatLogSplit.ranges(for: [activity("Live", start: 0, log: LogRange(fileName: "a.txt", startOffset: 0), ended: false)])
        }
        #expect(throws: CombatLogSplit.SplitError.notLogged(title: "Old")) {
            try CombatLogSplit.ranges(for: [activity("Old", start: 0, log: nil)])
        }
        #expect(throws: CombatLogSplit.SplitError.logMissing(fileName: "gone.txt")) {
            try CombatLogSplit.write([LogRange(fileName: "gone.txt", startOffset: 0)], from: folder,
                                     to: folder.appending(path: "Split.txt"))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Split.txt").path))
    }

    @Test func splitsARealKeyFromItsLog() throws {
        let url = try #require(Bundle.module.url(forResource: "mythic-plus", withExtension: "txt", subdirectory: "Fixtures"))
        var tracker = ActivityTracker()
        var library = Library()
        var buffer = LineBuffer()
        for (line, offset) in buffer.appendWithOffsets(try Data(contentsOf: url)) {
            if let entry = CombatLogParser.parse(line: line, position: LogPosition(fileName: "mythic-plus.txt", offset: offset)) {
                library.upsert(tracker.handle(entry))
            }
        }
        let key = try #require(library.activities.first)
        let destination = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try CombatLogSplit.write(try CombatLogSplit.ranges(for: [key]), from: url.deletingLastPathComponent(), to: destination)
        let lines = try String(contentsOf: destination, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 11)
        #expect(lines.first?.contains("COMBAT_LOG_VERSION") == true)
        #expect(lines[1].contains("CHALLENGE_MODE_START"))
        #expect(lines.last?.contains("CHALLENGE_MODE_END,2526,1,10") == true)
    }

    @Test func namesFilesLikeArchonDoes() {
        let utc = TimeZone(identifier: "UTC")!
        let key = activity("Ara-Kara: City of Echoes +12", start: 1_760_000_000, log: nil)
        let pull = activity("Ula'tek", start: 1_760_000_100, log: nil)
        #expect(CombatLogSplit.fileName(for: [key], timeZone: utc) == "Split-Ara-Kara City of Echoes +12-2025-10-09T085320.txt")
        let pair = CombatLogSplit.fileName(for: [pull, key], timeZone: utc)
        #expect(pair.hasPrefix("Split-Ara-Kara City of Echoes +12 and 1 more-2025-10-09T085320-"))
        #expect(pair == CombatLogSplit.fileName(for: [key, pull], timeZone: utc))
        // Another selection starting with the same key gets its own file.
        let other = activity("Pull 3", start: 1_760_000_200, log: nil)
        #expect(pair != CombatLogSplit.fileName(for: [key, other], timeZone: utc))
        #expect(CombatLogSplit.fileName(for: [pull], timeZone: utc) == "Split-Ula'tek-2025-10-09T085500.txt")
        #expect(!CombatLogSplit.fileName(for: [key]).hasPrefix("WoWCombatLog"))
    }
}
