import AVKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    let item: PlaybackItem
    @Environment(AppModel.self) private var model
    @State private var playback = PlaybackController()
    @State private var exportError: String?

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
            .frame(minWidth: 480)

            MarkerList(playback: playback)
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
        }
        .navigationTitle(item.title)
        .task(id: item) {
            await playback.load(item, segments: segments)
        }
        // The newest segment finishes up to a minute after the fact; pick it up when it lands.
        .onChange(of: segments.count) { old, new in
            guard new > old else { return }
            Task { await playback.load(item, segments: segments, keepPosition: true) }
        }
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
                    .keyboardShortcut("[", modifiers: [])
                    .help("Previous marker ( [ )")
                Button("Play/Pause", systemImage: "playpause.fill") { playback.togglePlayback() }
                    .keyboardShortcut("k", modifiers: [])
                    .help("Play/Pause ( K )")
                Button("Next Marker", systemImage: "forward.end.fill") { playback.jumpToNextMarker() }
                    .keyboardShortcut("]", modifiers: [])
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
                .frame(width: 260)

                Button("Export…", systemImage: "square.and.arrow.up") { export() }
                    .disabled(playback.duration == 0 || playback.isExporting)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(item.title).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await playback.export(to: url)
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

/// A scrub bar with the activity's markers drawn on it.
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
                ForEach(playback.markers) { timed in
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

private struct MarkerList: View {
    let playback: PlaybackController

    var body: some View {
        List {
            Section("Markers") {
                if playback.markers.isEmpty {
                    Text("No markers").foregroundStyle(.secondary)
                }
                ForEach(playback.markers) { timed in
                    Button {
                        playback.jump(to: timed)
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
                }
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
        }
    }
}
