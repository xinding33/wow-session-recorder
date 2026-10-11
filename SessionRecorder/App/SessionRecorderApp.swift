import SwiftUI

@main
struct SessionRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.model)
        }

        Window("WoW Session Recorder", id: WindowID.library) {
            LibraryView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 1280, height: 800)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

extension NSApplication {
    /// Quits from inside a task. `terminate` waits for `applicationShouldTerminate`'s reply in a
    /// run loop of its own, and when a main actor task starts that loop, no other main actor
    /// task runs in it: the shutdown never finishes and the app hangs. Starting from the run
    /// loop instead lets it through.
    func terminateFromTask() {
        RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }
}

enum WindowID {
    static let library = "library"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    override init() {
        LegacyInstall.migrate()
        model = AppModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Finish writing the open segment before quitting.
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
