import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Same glyph as idle, with only the centre dot red. Menu bar images are tinted to match
    /// the bar unless they opt out of template rendering; the ring uses `labelColor` so it
    /// still follows light and dark menu bars.
    private static let recordingIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed, .labelColor]))
        let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recording")!
            .withSymbolConfiguration(config)!
        image.isTemplate = false
        return image
    }()

    private static let idleIcon: NSImage = {
        let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Not recording")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))!
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: model.captureState.isRecording ? Self.recordingIcon : Self.idleIcon)
            .onAppear {
                // Show the library once so first-time users find the app.
                if !model.settings.hasLaunchedBefore {
                    model.settings.hasLaunchedBefore = true
                    openWindow(id: WindowID.library)
                }
            }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.captureState.statusText)
        if model.isRecordingEverythingAsFallback {
            Text("Combat log off: recording everything")
        }
        if let last = model.combatLogLastWrite {
            Text("Combat log updated \(last, style: .relative) ago")
        } else {
            Text("Combat log: no recent writes")
        }

        Divider()

        Button(model.settings.autoRecord ? "Pause Recording" : "Resume Recording") {
            model.setAutoRecord(!model.settings.autoRecord)
        }
        Button("Add Bookmark  \(Hotkey.bookmark.display)") { model.bookmark() }
        Button(model.isClipping ? "Stop Clip  \(Hotkey.clip.display)" : "Start Clip  \(Hotkey.clip.display)") {
            model.toggleClip()
        }

        Divider()

        Button("Open Library…") {
            openWindow(id: WindowID.library)
            NSApp.activate()
        }
        .keyboardShortcut("l")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")

        Divider()

        Button("Quit WoW Session Recorder") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
