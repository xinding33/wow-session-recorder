import AVKit
import Carbon.HIToolbox
import SwiftUI

/// Something the player does from the keyboard. The keys follow YouTube's, so most people
/// already know them.
enum PlayerCommand: Equatable {
    case togglePlayback
    case skip(seconds: Double)
    case stepFrame(by: Int)
    /// Steps through `PlaybackController.rates`.
    case changeSpeed(by: Int)
    case jump(toFraction: Double)
    case toggleFullScreen
    case toggleMute
    case previousMarker, nextMarker
    case previousDeath, nextDeath
    case setStart, setEnd, clearSelection
    case saveClip, export
    case showShortcuts

    /// The command for a key press. While `isTyping`, only ⌘ shortcuts count, so keys still
    /// type text. Keys are matched by the character they type, so layouts that need ⌥ for
    /// brackets (German, for one) still reach them.
    init?(_ event: NSEvent, isTyping: Bool) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": self = .saveClip
            case "e": self = .export
            default: return nil
            }
            return
        }
        guard !isTyping, modifiers.isDisjoint(with: [.command, .control]) else { return nil }

        if modifiers.isSubset(of: .shift) {
            switch Int(event.keyCode) {
            case kVK_Space: self = .togglePlayback; return
            case kVK_LeftArrow: self = .skip(seconds: modifiers == .shift ? -1 : -5); return
            case kVK_RightArrow: self = .skip(seconds: modifiers == .shift ? 1 : 5); return
            case kVK_Home: self = .jump(toFraction: 0); return
            case kVK_End: self = .jump(toFraction: 1); return
            case kVK_Escape: self = .clearSelection; return
            default: break
            }
        }

        switch event.characters?.lowercased() {
        case "k": self = .togglePlayback
        case "j": self = .skip(seconds: -10)
        case "l": self = .skip(seconds: 10)
        case ",": self = .stepFrame(by: -1)
        case ".": self = .stepFrame(by: 1)
        case "<": self = .changeSpeed(by: -1)
        case ">": self = .changeSpeed(by: 1)
        case "f": self = .toggleFullScreen
        case "m": self = .toggleMute
        case "[": self = .previousMarker
        case "]": self = .nextMarker
        case "{": self = .previousDeath
        case "}": self = .nextDeath
        case "i": self = .setStart
        case "o": self = .setEnd
        case "x": self = .clearSelection
        case "?": self = .showShortcuts
        case let key? where key.count == 1 && key.first!.isASCII && key.first!.isNumber:
            self = .jump(toFraction: Double(key)! / 10)
        default: return nil
        }
    }

    /// What the shortcuts sheet lists, in order.
    static let reference: [(section: String, shortcuts: [(keys: String, action: String)])] = [
        ("Playback", [
            ("Space or K", "Play or pause"),
            ("J / L", "Back or forward 10 seconds"),
            ("← / →", "Back or forward 5 seconds"),
            ("⇧← / ⇧→", "Back or forward 1 second"),
            (", / .", "Previous or next frame"),
            ("< / >", "Slower or faster"),
            ("0–9", "Jump to 0%–90% of the way through"),
            ("Home / End", "Jump to the start or end"),
            ("F", "Full screen"),
            ("M", "Mute"),
        ]),
        ("Markers", [
            ("[ / ]", "Previous or next marker"),
            ("{ / }", "Previous or next death, with its recap"),
        ]),
        ("Selection", [
            ("I / O", "Start or end the selection here"),
            ("Esc or X", "Clear the selection"),
            ("⌘S", "Save the selection as a clip"),
            ("⌘E", "Export the selection, or everything"),
        ]),
        ("Help", [
            ("?", "Show these shortcuts"),
        ]),
    ]
}

/// Runs the player's shortcuts wherever focus is in its window, and in full screen, which
/// AVPlayerView shows in a window of its own. Without this, Space and the arrow keys only
/// reached the video after clicking it.
@MainActor
final class PlayerKeyMonitor: NSObject, @MainActor AVPlayerViewDelegate {
    weak var view: AVPlayerView?
    /// Runs a command; returns whether it applied, so a key that did nothing passes through.
    var perform: (PlayerCommand) -> Bool = { _ in false }
    private var monitor: Any?
    /// AVPlayerView's content, which moves into the full screen window. Finding it there tells
    /// that window apart from others, like a save panel opened from full screen.
    private var content: [NSView] = []

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns whether the key was used.
    private func handle(_ event: NSEvent) -> Bool {
        guard let view, let window = event.window else { return false }
        let isFullScreen = view.isInFullScreen
        if !isFullScreen { content = view.subviews }
        guard window === view.window || (isFullScreen && content.contains { $0.window === window }) else { return false }
        // Esc leaves full screen.
        if isFullScreen, Int(event.keyCode) == kVK_Escape { return false }
        guard let command = PlayerCommand(event, isTyping: window.firstResponder is NSText) else { return false }
        if command == .toggleFullScreen {
            view.toggleFullScreen()
            return true
        }
        return perform(command)
    }

    /// The content only exists once the view is in a window, so it's picked up here too, for
    /// full screen entered with the mouse before any key press.
    func playerViewWillEnterFullScreen(_ playerView: AVPlayerView) {
        content = playerView.subviews
    }
}

extension AVPlayerView {
    /// AVPlayerView's own full screen has no public API; its full screen button calls these.
    var isInFullScreen: Bool {
        responds(to: Selector(("isFullScreen"))) && (value(forKey: "fullScreen") as? Bool ?? false)
    }

    func toggleFullScreen() {
        let action = Selector(isInFullScreen ? "exitFullScreen:" : "enterFullScreen:")
        if responds(to: action) { perform(action, with: nil) }
    }
}

struct PlayerShortcutsView: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(PlayerCommand.reference, id: \.section) { group in
                GridRow {
                    Text(group.section)
                        .font(.headline)
                        .gridCellColumns(2)
                        .padding(.top, group.section == PlayerCommand.reference.first?.section ? 0 : 8)
                }
                ForEach(group.shortcuts, id: \.keys) { shortcut in
                    GridRow {
                        Text(shortcut.keys)
                            .fontWeight(.medium)
                            .gridColumnAlignment(.trailing)
                        Text(shortcut.action)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
    }
}
