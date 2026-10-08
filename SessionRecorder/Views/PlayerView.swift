import AVKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

extension EnvironmentValues {
    /// Whether the player's single-letter shortcuts (K, I, O…) are on.
    @Entry var allowsPlainKeyShortcuts = true
}

struct PlayerView: View {
    let item: PlaybackItem
    @Environment(AppModel.self) private var model
    @State private var playback = PlaybackController()
    @State private var exportError: String?
    /// The death whose recap is showing in the side panel.
    @State private var recapMarker: Marker?
    @State private var savedClipMessage: String?
    /// Plain-letter shortcuts are off while typing notes, or they'd eat the letters.
    @FocusState private var isEditingNotes: Bool
    /// Off while typing somewhere else in the window, e.g. the library's search field.
    @Environment(\.allowsPlainKeyShortcuts) private var allowsPlainKeyShortcuts

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ZStack {
                    PlayerSurface(player: playback.player)
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

            SidePanel(playback: playback, activityID: item.activityID, recapMarker: $recapMarker,
                      notesFocus: $isEditingNotes)
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
        .onAppear { playback.hiddenCategories = model.settings.hiddenMarkerCategories }
        .onChange(of: model.settings.hiddenMarkerCategories) { _, hidden in playback.hiddenCategories = hidden }
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
                    .keyboardShortcut(shortcut("["))
                    .help("Previous marker ( [ )")
                Button("Play/Pause", systemImage: "playpause.fill") { playback.togglePlayback() }
                    .keyboardShortcut(shortcut("k"))
                    .help("Play/Pause ( K )")
                Button("Next Marker", systemImage: "forward.end.fill") { playback.jumpToNextMarker() }
                    .keyboardShortcut(shortcut("]"))
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
                    ForEach([Float(0.25), 0.5, 1, 1.5, 2], id: \.self) { rate in
                        Text(rate == 1 ? "1×" : "\(rate.formatted())×").tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
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
                .keyboardShortcut(shortcut("i"))
                .help("Start the selection here ( I )")
            Button("Set End", systemImage: "arrow.left.to.line") { playback.setOutPoint() }
                .keyboardShortcut(shortcut("o"))
                .help("End the selection here ( O )")

            if let selection = playback.selection {
                Text("Selected \(formatTime(selection.lowerBound))–\(formatTime(selection.upperBound)) (\(formatTime(selection.upperBound - selection.lowerBound)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Clear Selection", systemImage: "xmark.circle.fill") { playback.clearSelection() }
                    .keyboardShortcut(shortcut("x"))
                    .help("Clear the selection ( X )")
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
                .help("Keep the selection in the library as a clip")

            Menu {
                Button("Export Selection…") { export(range: playback.selection) }
                    .disabled(playback.selection == nil)
                Button("Export Everything…") { export(range: nil) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(playback.duration == 0 || playback.isExporting)
            .help("Export to an MP4 file")
        }
    }

    private func shortcut(_ key: KeyEquivalent) -> KeyboardShortcut? {
        isEditingNotes || !allowsPlainKeyShortcuts ? nil : KeyboardShortcut(key, modifiers: [])
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

/// AppKit's player view: native scrubbing, frame stepping (←/→), fullscreen and PiP.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFrameSteppingButtons = true
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
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

/// Markers (with the death recap underneath when a death is picked) and, for library
/// activities, notes.
private struct SidePanel: View {
    enum Tab { case markers, notes }

    let playback: PlaybackController
    let activityID: Activity.ID?
    @Binding var recapMarker: Marker?
    var notesFocus: FocusState<Bool>.Binding
    @State private var tab = Tab.markers

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if activityID != nil {
                    Picker("Show", selection: $tab) {
                        Text("Markers").tag(Tab.markers)
                        Text("Notes").tag(Tab.notes)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } else {
                    Text("Markers").font(.headline)
                }
                Spacer()
                if tab == .markers {
                    MarkerFilterMenu(categories: playback.markerCategories)
                }
            }
            .padding(8)
            Divider()

            if tab == .notes, let activityID {
                NotesEditor(activityID: activityID)
                    .focused(notesFocus)
            } else {
                MarkerList(playback: playback, recapMarker: $recapMarker)
                if let recapMarker {
                    Divider()
                    DeathRecapPanel(marker: recapMarker, playback: playback) { self.recapMarker = nil }
                        .frame(minHeight: 200, idealHeight: 320)
                }
            }
        }
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
    @Binding var recapMarker: Marker?

    var body: some View {
        List {
            if playback.visibleMarkers.isEmpty {
                Text(playback.markers.isEmpty ? "No markers" : "All markers are hidden")
                    .foregroundStyle(.secondary)
            }
            ForEach(playback.visibleMarkers) { timed in
                Button {
                    playback.jump(to: timed)
                    if timed.marker.kind.category == .deaths { recapMarker = timed.marker }
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
                .listRowBackground(timed.marker.id == recapMarker?.id ? Color.accentColor.opacity(0.15) : nil)
                .help(timed.marker.kind.category == .deaths ? "Jump here and show what led to this death" : "")
            }
        }
    }
}

/// What hit someone in the seconds before they died. Click a line to see it on the video.
private struct DeathRecapPanel: View {
    let marker: Marker
    let playback: PlaybackController
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @State private var state = LoadState.loading
    @State private var showHealing = true

    enum LoadState {
        case loading
        case loaded(DeathRecap)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Death Recap").font(.headline)
                Text(marker.kind == .playerDeath ? "You" : marker.label.replacingOccurrences(of: " died", with: ""))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Toggle("Healing", isOn: $showHealing)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Show healing received")
                Button("Close", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding([.horizontal, .top], 8)

            switch state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .loaded(let recap):
                summary(recap)
                    .padding(.horizontal, 8)
                List(recap.events.filter { showHealing || $0.kind != .heal }.reversed()) { event in
                    Button {
                        playback.seek(to: event.date, leadIn: 1)
                    } label: {
                        RecapRow(event: event, death: marker.date)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: marker.id) {
            state = .loading
            do {
                state = .loaded(try await model.deathRecap(for: marker))
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private func summary(_ recap: DeathRecap) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let blow = recap.killingBlow {
                Text("Killed by \(blow.ability) from \(blow.source)")
                    .fontWeight(.medium)
            }
            Text("Last \(Int(DeathRecap.window)) s: \(formatAmount(recap.damageTaken)) damage taken, \(formatAmount(recap.healingReceived)) healing")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RecapRow: View {
    let event: DeathRecap.Event
    let death: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(offsetText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.ability).lineLimit(1)
                Text(event.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(amountText)
                    .monospacedDigit()
                    .fontWeight(event.isCritical ? .semibold : .regular)
                    .foregroundStyle(event.kind == .heal ? .green : .red)
                if let percent = event.healthPercent {
                    HealthBar(percent: percent)
                }
            }
        }
        .contentShape(Rectangle())
        .help(details)
    }

    /// Seconds before the death. Rounding would show "-0.0s" for the killing blow.
    private var offsetText: String {
        let offset = event.date.timeIntervalSince(death)
        return abs(offset) < 0.05 ? "0.0s" : String(format: "%.1fs", offset)
    }

    private var amountText: String {
        switch event.kind {
        case .heal: "+\(formatAmount(event.amount))"
        case .damage: "−\(formatAmount(event.amount))"
        case .instakill: "Instant kill"
        }
    }

    private var details: String {
        var parts: [String] = []
        if event.isCritical { parts.append("Critical") }
        if event.absorbed > 0 { parts.append("\(formatAmount(event.absorbed)) absorbed") }
        if event.overkill > 0 { parts.append("\(formatAmount(event.overkill)) overkill") }
        if let health = event.health, let max = event.maxHealth {
            parts.append("Health after: \(formatAmount(health)) of \(formatAmount(max))")
        }
        return parts.joined(separator: "\n")
    }
}

private struct HealthBar: View {
    let percent: Double

    var body: some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(.quaternary)
                .frame(width: 40, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: 40 * min(max(percent, 0), 100) / 100, height: 4)
                }
            Text("\(Int(percent.rounded()))%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var color: Color {
        percent > 50 ? .green : percent > 25 ? .yellow : .red
    }
}

private func formatAmount(_ amount: Int) -> String {
    amount.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
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
