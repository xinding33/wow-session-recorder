import AppKit

/// Reports when retail WoW launches or quits.
@MainActor
final class GameWatcher {
    private var observers: [NSObjectProtocol] = []
    private let onChange: @MainActor (Bool) -> Void

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    var isGameRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: WoWInstall.bundleID).isEmpty
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == WoWInstall.bundleID else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onChange(self.isGameRunning)
                }
            })
        }
        onChange(isGameRunning)
    }
}
