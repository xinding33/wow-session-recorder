import Foundation
import Observation
import RecorderCore
import ServiceManagement

enum RecordingScope: String, CaseIterable, Identifiable {
    case always
    case instancesOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .always: "Always while WoW runs"
        case .instancesOnly: "Only in instances"
        }
    }
}

enum LaunchMode: String, CaseIterable, Identifiable {
    case withWoW
    case atLogin
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .withWoW: "When WoW launches"
        case .atLogin: "At login"
        case .manual: "Manually"
        }
    }
}

/// User preferences, persisted to `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var autoRecord: Bool { didSet { defaults.set(autoRecord, forKey: "autoRecord") } }
    var quality: CaptureQuality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    var fps: Int { didSet { defaults.set(fps, forKey: "fps") } }
    var captureAudio: Bool { didSet { defaults.set(captureAudio, forKey: "captureAudio") } }
    /// 0 keeps unmarked footage forever.
    var keepUnmarkedHours: Int { didSet { defaults.set(keepUnmarkedHours, forKey: "keepUnmarkedHours") } }
    /// 0 keeps activities forever.
    var keepActivitiesDays: Int { didSet { defaults.set(keepActivitiesDays, forKey: "keepActivitiesDays") } }
    var recordingsPath: String { didSet { defaults.set(recordingsPath, forKey: "recordingsPath") } }
    /// Overrides auto-detection when set.
    var wowRetailPath: String? { didSet { defaults.set(wowRetailPath, forKey: "wowRetailPath") } }
    var hasLaunchedBefore: Bool { didSet { defaults.set(hasLaunchedBefore, forKey: "hasLaunchedBefore") } }
    var launchMode: LaunchMode { didSet { defaults.set(launchMode.rawValue, forKey: "launchMode") } }
    /// Apps opened when WoW launches and, optionally, quit when it quits.
    var companionAppPaths: [String] { didSet { defaults.set(companionAppPaths, forKey: "companionAppPaths") } }
    var quitCompanionsWithWoW: Bool { didSet { defaults.set(quitCompanionsWithWoW, forKey: "quitCompanionsWithWoW") } }
    var recordingScope: RecordingScope { didSet { defaults.set(recordingScope.rawValue, forKey: "recordingScope") } }

    init() {
        defaults.register(defaults: [
            "autoRecord": true,
            "quality": CaptureQuality.p1440.rawValue,
            "fps": 60,
            "captureAudio": true,
            "keepUnmarkedHours": 24,
            "keepActivitiesDays": 30,
            "quitCompanionsWithWoW": true,
        ])
        autoRecord = defaults.bool(forKey: "autoRecord")
        quality = CaptureQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .p1440
        fps = defaults.integer(forKey: "fps")
        captureAudio = defaults.bool(forKey: "captureAudio")
        keepUnmarkedHours = defaults.integer(forKey: "keepUnmarkedHours")
        keepActivitiesDays = defaults.integer(forKey: "keepActivitiesDays")
        recordingsPath = defaults.string(forKey: "recordingsPath")
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appending(path: "WoW Session Recorder").path
        wowRetailPath = defaults.string(forKey: "wowRetailPath")
        hasLaunchedBefore = defaults.bool(forKey: "hasLaunchedBefore")
        // Earlier versions only had a launch-at-login toggle; carry that choice over.
        launchMode = LaunchMode(rawValue: defaults.string(forKey: "launchMode") ?? "")
            ?? (SMAppService.mainApp.status == .enabled ? .atLogin : .manual)
        companionAppPaths = defaults.stringArray(forKey: "companionAppPaths") ?? []
        quitCompanionsWithWoW = defaults.bool(forKey: "quitCompanionsWithWoW")
        recordingScope = RecordingScope(rawValue: defaults.string(forKey: "recordingScope") ?? "") ?? .always
    }

    var companionAppURLs: [URL] { companionAppPaths.map { URL(fileURLWithPath: $0) } }

    var recordingsURL: URL { URL(fileURLWithPath: recordingsPath, isDirectory: true) }

    var retention: RetentionPolicy {
        RetentionPolicy(
            keepUnmarkedFootage: keepUnmarkedHours > 0 ? TimeInterval(keepUnmarkedHours) * 3600 : nil,
            keepActivities: keepActivitiesDays > 0 ? TimeInterval(keepActivitiesDays) * 86400 : nil,
            paddingBefore: AppSettings.paddingBefore,
            paddingAfter: AppSettings.paddingAfter
        )
    }

    /// Footage shown before an activity starts, e.g. the run-in to a pull.
    static let paddingBefore: TimeInterval = 10
    /// Footage shown after an activity ends.
    static let paddingAfter: TimeInterval = 5
}
