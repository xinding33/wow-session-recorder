import AVKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    let item: PlaybackItem
    @Environment(AppModel.self) private var model
    @State private var playback = PlaybackController()
    @State private var exportError: String?
    /// The death whose recap is showing in the side panel.
    @State private var recapMarker: Marker.ID?
    @State private var recaps = DeathRecapStore()
    @State private var savedClipMessage: String?
    @State private var showsShortcuts = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ZStack {
                    PlayerSurface(player: playback.player, perform: perform)
                    if playback.isLoading {
                        ProgressView()
                    } else if let message = playback.errorMessage {
                        ContentUnavailableView("No Footage", systemImage: "film", description: Text(message))
                    }
                }
                .background(.black)

                if item.isLive || playback.pendingSeconds > 1 || playback.pendingMarkerCount > 0 {
                    PendingFootageBanner(isLive: item.isLive, seconds: playback.pendingSeconds,
                                         markers: playback.pendingMarkerCount)
                }

                controls
                    .padding(12)
            }
            .frame(minWidth: 520)

            SidePanel(playback: playback, activityID: item.activityID, recapMarker: $recapMarker, recaps: recaps,
                      open: open)
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
        }
        .navigationTitle(item.title)
        .task(id: item) {
            await playback.load(item, segments: segments)
        }
        // The newest segment finishes up to a minute after the fact; pick it up when it lands.
        .onChange(of: segments.count) { old, new in
            guard new > old else { return }
            Task { await playback.load(item, segments: segments) }
        }
        .onChange(of: item.identity) { recapMarker = nil }
        .onAppear {
            playback.hiddenCategories = model.settings.hiddenMarkerCategories
            playback.cooldownChoices = model.settings.cooldownChoices
            playback.learnedCooldowns = model.learnedCooldowns
        }
        .onChange(of: model.settings.hiddenMarkerCategories) { _, hidden in playback.hiddenCategories = hidden }
        .onChange(of: model.settings.cooldownChoices) { _, choices in playback.cooldownChoices = choices }
        .onChange(of: model.learnedCooldowns) { _, learned in playback.learnedCooldowns = learned }
        .onDisappear { playback.stop() }
        .alert("Export Failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var segments: [Segment] {
        model.segments(from: item.start.addingTimeInterval(-AppSettings.paddingBefore),
                       to: item.end.addingTimeInterval(AppSettings.paddingAfter))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            MarkerTimeline(playback: playback)

            HStack(spacing: 12) {
                Button("Previous Marker", systemImage: "backward.end.fill") { playback.jumpToPreviousMarker() }
                    .help("Previous marker ( [ )")
                Button("Play/Pause", systemImage: "playpause.fill") { playback.togglePlayback() }
                    .help("Play/Pause ( Space )")
                Button("Next Marker", systemImage: "forward.end.fill") { playback.jumpToNextMarker() }
                    .help("Next marker ( ] )")

                Text("\(formatTime(playback.currentTime)) / \(formatTime(playback.duration))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let wallClock = playback.currentWallClock {
                    Text(wallClock, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .help("When this moment happened")
                }

                Spacer()

                Picker("Speed", selection: Binding(get: { playback.rate }, set: { playback.rate = $0 })) {
                    ForEach(PlaybackController.rates, id: \.self) { rate in
                        Text(rate == 1 ? "1×" : "\(rate.formatted())×").tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .help("Playback speed ( < and > )")
            }

            trimBar
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    /// In/out points, and what to do with the selection.
    private var trimBar: some View {
        HStack(spacing: 12) {
            Button("Set Start", systemImage: "arrow.right.to.line") { playback.setInPoint() }
                .help("Start the selection here ( I )")
            Button("Set End", systemImage: "arrow.left.to.line") { playback.setOutPoint() }
                .help("End the selection here ( O )")

            if let selection = playback.selection {
                Text("Selected \(formatTime(selection.lowerBound))–\(formatTime(selection.upperBound)) (\(formatTime(selection.upperBound - selection.lowerBound)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Clear Selection", systemImage: "xmark.circle.fill") { playback.clearSelection() }
                    .help("Clear the selection ( Esc )")
            } else {
                Text("Press I and O to select part of the video")
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if let savedClipMessage {
                Text(savedClipMessage)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Button("Save as Clip", systemImage: "scissors") { saveClip() }
                .disabled(playback.selectionDates == nil)
                .help("Keep the selection in the library as a clip ( ⌘S )")

            let cannotExportVideo = playback.duration == 0 || playback.isExporting
            Menu {
                Button("Export Selection…") { export(range: playback.selection) }
                    .disabled(playback.selection == nil || cannotExportVideo)
                Button("Export Everything…") { export(range: nil) }
                    .disabled(cannotExportVideo)
                if let id = item.activityID {
                    Divider()
                    Button("Upload to Warcraft Logs…") { model.uploadToWarcraftLogs([id]) }
                        .disabled(item.isLive || model.isPreparingUpload)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(item.activityID == nil && cannotExportVideo)
            .help(item.activityID == nil ? "Export to an MP4 file ( ⌘E )" : "Export to an MP4 file ( ⌘E ) or upload to Warcraft Logs")

            Button("Keyboard Shortcuts", systemImage: "keyboard") { showsShortcuts.toggle() }
                .help("Keyboard shortcuts ( ? )")
                .popover(isPresented: $showsShortcuts) { PlayerShortcutsView() }
        }
    }

    /// Runs a keyboard shortcut. Returns false when it had nothing to act on, so the key
    /// passes through.
    private func perform(_ command: PlayerCommand) -> Bool {
        switch command {
        case .togglePlayback: playback.togglePlayback()
        case .skip(let seconds): playback.skip(by: seconds)
        case .stepFrame(let count): playback.stepFrame(by: count)
        case .changeSpeed(let steps): playback.changeSpeed(by: steps)
        case .jump(let fraction): playback.jump(toFraction: fraction)
        case .toggleMute: playback.toggleMute()
        case .previousMarker: playback.jumpToPreviousMarker()
        case .nextMarker: playback.jumpToNextMarker()
        case .previousDeath, .nextDeath:
            guard let death = playback.death(command == .nextDeath ? 1 : -1, from: recapMarker) else { return false }
            open(death)
        case .setStart: playback.setInPoint()
        case .setEnd: playback.setOutPoint()
        case .clearSelection:
            guard playback.selection != nil else { return false }
            playback.clearSelection()
        case .saveClip:
            guard playback.selectionDates != nil else { return false }
            saveClip()
        case .export:
            guard playback.duration > 0, !playback.isExporting else { return false }
            let range = playback.selection
            // Not from inside the key event: the save panel runs its own event loop.
            DispatchQueue.main.async { export(range: range) }
        case .showShortcuts: showsShortcuts.toggle()
        case .toggleFullScreen: return false
        }
        return true
    }

    /// Plays the lead-up to a death and shows what led to it. Starting further back than other
    /// markers gives the recap time to follow along.
    private func open(_ death: PlaybackController.TimedMarker) {
        playback.seek(to: death.time - 5)
        playback.play()
        recapMarker = death.id
    }

    private func saveClip() {
        guard let dates = playback.selectionDates else { return }
        model.saveClip(of: item, from: dates.start, to: dates.end)
        withAnimation { savedClipMessage = "Saved to Clips" }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { savedClipMessage = nil }
        }
    }

    private func export(range: ClosedRange<Double>?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = range == nil ? "\(item.title).mp4" : "\(item.title) (clip).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await playback.export(to: url, range: range)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    return ActivityTracker.formatDuration(max(seconds, 0))
}

private struct PendingFootageBanner: View {
    let isLive: Bool
    let seconds: Double
    let markers: Int

    private var message: String {
        if isLive { return "In progress. New footage appears here about once a minute." }
        if markers > 0 {
            return "The last \(formatTime(seconds)) and \(markers) marker(s) are still being recorded. They'll appear here within a minute."
        }
        return "The last \(formatTime(seconds)) is still being recorded. It'll appear here within a minute."
    }

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.12))
    }
}

/// AppKit's player view: native scrubbing, frame stepping, fullscreen and PiP. It also hosts
/// the player's keyboard shortcuts.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let perform: (PlayerCommand) -> Bool

    func makeCoordinator() -> PlayerKeyMonitor {
        PlayerKeyMonitor()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFrameSteppingButtons = true
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.perform = perform
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        context.coordinator.perform = perform
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: PlayerKeyMonitor) {
        coordinator.stop()
    }
}

/// A scrub bar with the activity's markers and the trim selection drawn on it.
private struct MarkerTimeline: View {
    let playback: PlaybackController

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x: (Double) -> CGFloat = { time in
                playback.duration > 0 ? CGFloat(time / playback.duration) * width : 0
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 6)
                Capsule().fill(.tint).frame(width: x(playback.currentTime), height: 6)
                if let selection = playback.selection {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.25))
                        .overlay(alignment: .leading) { Rectangle().fill(.tint).frame(width: 2) }
                        .overlay(alignment: .trailing) { Rectangle().fill(.tint).frame(width: 2) }
                        .frame(width: max(x(selection.upperBound) - x(selection.lowerBound), 2), height: 22)
                        .offset(x: x(selection.lowerBound))
                        .allowsHitTesting(false)
                }
                ForEach(playback.visibleMarkers) { timed in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(timed.marker.kind.color)
                        .frame(width: 3, height: 18)
                        .offset(x: x(timed.time) - 1.5)
                        .help("\(formatTime(timed.time))  \(timed.marker.label)")
                }
                Circle()
                    .fill(.white)
                    .shadow(radius: 1)
                    .frame(width: 12, height: 12)
                    .offset(x: x(playback.currentTime) - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard width > 0 else { return }
                playback.seek(to: Double(value.location.x / width) * playback.duration)
            })
        }
        .frame(height: 22)
    }
}

/// Markers, deaths and, for library activities, notes. Picking a death shows its recap in
/// place of the tabs until you go back.
private struct SidePanel: View {
    enum Tab { case markers, deaths, notes }

    let playback: PlaybackController
    let activityID: Activity.ID?
    @Binding var recapMarker: Marker.ID?
    let recaps: DeathRecapStore
    let open: (PlaybackController.TimedMarker) -> Void
    @State private var tab = Tab.markers

    var body: some View {
        let deaths = playback.deaths
        VStack(spacing: 0) {
            if let death = deaths.first(where: { $0.id == recapMarker }) {
                DeathRecapView(death: death, deaths: deaths, backTitle: tab == .deaths ? "Deaths" : "Markers",
                               playback: playback, recaps: recaps, select: open) { recapMarker = nil }
            } else {
                HStack {
                    Picker("Show", selection: $tab) {
                        Text("Markers").tag(Tab.markers)
                        Text(deaths.isEmpty ? "Deaths" : "Deaths (\(deaths.count))").tag(Tab.deaths)
                        if activityID != nil {
                            Text("Notes").tag(Tab.notes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Spacer()
                    if tab == .markers {
                        MarkerFilterMenu(categories: playback.markerCategories)
                    }
                }
                .padding(8)
                Divider()

                switch tab {
                case .notes:
                    if let activityID {
                        NotesEditor(activityID: activityID)
                    }
                case .deaths:
                    DeathList(deaths: deaths, recaps: recaps, open: open)
                case .markers:
                    MarkerList(playback: playback, openDeath: open)
                }
            }
        }
        // Footage sessions have no notes.
        .onChange(of: activityID) { if activityID == nil, tab == .notes { tab = .markers } }
    }
}

private struct MarkerFilterMenu: View {
    let categories: [MarkerCategory]
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(categories) { category in
                Toggle(category.displayName, isOn: Binding(
                    get: { !model.settings.hiddenMarkerCategories.contains(category) },
                    set: { shown in
                        if shown {
                            model.settings.hiddenMarkerCategories.remove(category)
                        } else {
                            model.settings.hiddenMarkerCategories.insert(category)
                        }
                    }))
            }
            if categories.isEmpty {
                Text("No markers")
            }
        } label: {
            Label("Show Markers", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Choose which markers to show")
    }
}

private struct MarkerList: View {
    let playback: PlaybackController
    let openDeath: (PlaybackController.TimedMarker) -> Void

    var body: some View {
        List {
            if playback.visibleMarkers.isEmpty {
                Text(playback.markers.isEmpty ? "No markers" : "All markers are hidden")
                    .foregroundStyle(.secondary)
            }
            ForEach(playback.visibleMarkers) { timed in
                Button {
                    if timed.marker.kind.category == .deaths {
                        openDeath(timed)
                    } else {
                        playback.jump(to: timed)
                    }
                } label: {
                    HStack {
                        Image(systemName: timed.marker.kind.symbol)
                            .foregroundStyle(timed.marker.kind.color)
                            .frame(width: 18)
                        Text(timed.marker.label)
                            .lineLimit(1)
                        Spacer()
                        Text(formatTime(timed.time))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(timed.marker.kind.category == .deaths ? "Jump here and show what led to this death" : "")
            }
        }
    }
}

/// Free-form notes on a library activity, saved as you type.
private struct NotesEditor: View {
    let activityID: Activity.ID
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("What went well, what to fix next time…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .task(id: activityID) {
                text = model.activities.first { $0.id == activityID }?.notes ?? ""
            }
            .onChange(of: text) { _, new in
                if new != (model.activities.first { $0.id == activityID }?.notes ?? "") {
                    model.setNotes(new, for: activityID)
                }
            }
    }
}

extension Marker.Kind {
    var color: Color {
        switch self {
        case .bossPull: .blue
        case .bossKill: .green
        case .bossWipe: .orange
        case .playerDeath: .red
        case .death: .pink
        case .bookmark: .yellow
        case .interrupt: .cyan
        case .dispel: .teal
        case .cooldown: .purple
        case .bloodlust: .indigo
        case .battleRes: .mint
        }
    }

    var symbol: String {
        switch self {
        case .bossPull: "flag.fill"
        case .bossKill: "checkmark.seal.fill"
        case .bossWipe: "xmark.octagon.fill"
        case .playerDeath: "heart.slash.fill"
        case .death: "person.fill.xmark"
        case .bookmark: "bookmark.fill"
        case .interrupt: "hand.raised.fill"
        case .dispel: "sparkles"
        case .cooldown: "bolt.fill"
        case .bloodlust: "flame.fill"
        case .battleRes: "cross.circle.fill"
        }
    }
}
