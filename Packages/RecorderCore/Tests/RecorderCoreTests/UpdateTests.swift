import Foundation
import Testing
@testable import RecorderCore

/// Each test builds its apps in its own throwaway folder.
final class UpdateTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func versionsCompareNumerically() throws {
        func version(_ string: String) throws -> Version { try #require(Version(string)) }
        #expect(try version("1.9.0") < version("1.10.0"))
        #expect(try version("1.1.0") < version("v1.1.1"))
        #expect(try version("v1.1") == version("1.1.0"))
        #expect(try version("v1.1.0").description == "1.1.0")
        #expect(Version("1.1.0-beta") == nil)
        #expect(Version("") == nil)
    }

    @Test func releaseFindsTheZip() throws {
        let json = """
            {"tag_name": "v1.2.0", "html_url": "https://github.com/xinding33/wow-session-recorder/releases/tag/v1.2.0",
             "assets": [
               {"name": "WoW-Session-Recorder-1.2.0.dmg",
                "browser_download_url": "https://github.com/xinding33/wow-session-recorder/releases/download/v1.2.0/WoW-Session-Recorder-1.2.0.dmg"},
               {"name": "WoW-Session-Recorder-1.2.0.zip",
                "browser_download_url": "https://github.com/xinding33/wow-session-recorder/releases/download/v1.2.0/WoW-Session-Recorder-1.2.0.zip"}]}
            """
        let release = try Release(gitHubJSON: Data(json.utf8))
        #expect(release.version == Version("1.2.0"))
        #expect(release.page.absoluteString == "https://github.com/xinding33/wow-session-recorder/releases/tag/v1.2.0")
        #expect(release.download.lastPathComponent == "WoW-Session-Recorder-1.2.0.zip")

        // Releases before the app could update itself only have a disk image.
        let noZip = """
            {"tag_name": "v0.1.0", "html_url": "https://example.com",
             "assets": [{"name": "WoW-Session-Recorder-0.1.0.dmg", "browser_download_url": "https://example.com/a.dmg"}]}
            """
        #expect(throws: UpdateError.noDownload) { try Release(gitHubJSON: Data(noZip.utf8)) }
    }

    @Test func installsUpdateSignedLikeTheApp() async throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try zip(makeApp(in: "update", version: "1.2.0"))
        try await Updater.install(zip: update, version: #require(Version("1.2.0")), replacing: app)
        #expect(version(of: app) == "1.2.0")
    }

    @Test func rejectsUpdateSignedDifferently() async throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try zip(makeApp(in: "update", identifier: "test.impostor", version: "1.2.0"))
        await #expect(throws: UpdateError.badSignature) {
            try await Updater.install(zip: update, version: #require(Version("1.2.0")), replacing: app)
        }
        #expect(version(of: app) == "1.1.0")
    }

    @Test func rejectsUpdateOfTheWrongVersion() async throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try zip(makeApp(in: "update", version: "1.0.0"))
        await #expect(throws: UpdateError.wrongVersion) {
            try await Updater.install(zip: update, version: #require(Version("1.2.0")), replacing: app)
        }
        #expect(version(of: app) == "1.1.0")
    }

    @Test func rejectsModifiedUpdate() async throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try makeApp(in: "update", version: "1.2.0")
        try Data("tampered".utf8).write(to: update.appendingPathComponent("Contents/MacOS/SessionRecorder"))
        let tampered = try zip(update)
        await #expect(throws: UpdateError.badSignature) {
            try await Updater.install(zip: tampered, version: #require(Version("1.2.0")), replacing: app)
        }
        #expect(version(of: app) == "1.1.0")
    }

    @Test func sourceBuildIsNotDeveloperIDSigned() throws {
        #expect(!Updater.isDeveloperIDSigned(try makeApp(in: "installed", version: "1.1.0")))
    }

    // MARK: - Fixtures

    /// An ad-hoc signed app whose designated requirement is just its identifier.
    private func makeApp(in name: String, identifier: String = "test.recorder", version: String) throws -> URL {
        let app = folder.appendingPathComponent(name).appendingPathComponent(Updater.appName)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("SessionRecorder").path)
        let info: NSDictionary = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "SessionRecorder",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
        ]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", "--force", "--sign", "-", "-r=designated => identifier \"\(identifier)\"", app.path)
        return app
    }

    /// Zips `app` the way scripts/release.sh does.
    private func zip(_ app: URL) throws -> URL {
        let zip = app.deletingLastPathComponent().appendingPathComponent("update.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path)
        return zip
    }

    private func run(_ path: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(path) \(arguments)")
    }

    private func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }
}
