import RecorderCore
import SwiftUI

enum LibraryFilter: Hashable {
    case all
    case favorites
    case kind(ActivityKind)
    case footage
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: LibraryFilter = .all
    @State private var selectedActivityID: Activity.ID?
    @State private var selectedSessionID: FootageSession.ID?

    var body: some View {
        NavigationSplitView {
            Sidebar(filter: $filter)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            Group {
                if filter == .footage {
                    SessionList(selection: $selectedSessionID)
                } else {
                    ActivityList(activities: filteredActivities, selection: $selectedActivityID)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            detail
        }
        .onAppear {
            // Behave like a regular app (Dock icon, ⌘-Tab) while the library is open.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            model.libraryVisibilityChanged(true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
            model.libraryVisibilityChanged(false)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if filter == .footage {
            if let session = model.sessions.first(where: { $0.id == selectedSessionID }) {
                PlayerView(item: playbackItem(for: session))
            } else {
                ContentUnavailableView("Select a Session", systemImage: "film.stack",
                                       description: Text("Recent footage is kept for \(model.settings.keepUnmarkedHours) hours."))
            }
        } else if let activity = model.activities.first(where: { $0.id == selectedActivityID }) {
            PlayerView(item: PlaybackItem(
                title: activity.title, start: activity.start, end: activity.end ?? .distantFuture,
                markers: activity.markers, focus: focus(for: activity)))
        } else {
            ContentUnavailableView("Select an Activity", systemImage: "play.rectangle")
        }
    }

    /// Bookmark clips open just before the first bookmark rather than 40 seconds earlier.
    private func focus(for activity: Activity) -> Date? {
        guard activity.kind == .clip,
              let bookmark = activity.markers.first(where: { $0.kind == .bookmark }) else { return nil }
        return bookmark.date.addingTimeInterval(-PlaybackController.markerLeadIn)
    }

    private var filteredActivities: [Activity] {
        switch filter {
        case .all, .footage: model.activities
        case .favorites: model.activities.filter(\.isFavorite)
        case .kind(let kind): model.activities.filter { $0.kind == kind }
        }
    }

    /// A whole session, with every activity inside it marked on the timeline.
    private func playbackItem(for session: FootageSession) -> PlaybackItem {
        let markers = model.activities
            .filter { $0.start < session.end && ($0.end ?? Date()) > session.start }
            .flatMap { activity in
                let hasStartMarker = activity.markers.first?.date == activity.start
                let start = Marker(date: activity.start, kind: .bossPull, label: activity.title)
                return (hasStartMarker ? [] : [start]) + activity.markers
            }
        return PlaybackItem(title: session.start.formatted(date: .abbreviated, time: .shortened),
                            start: session.start, end: session.end, markers: markers)
    }
}

private struct Sidebar: View {
    @Binding var filter: LibraryFilter
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: $filter) {
            Section("Activities") {
                Label("All", systemImage: "tray.full").tag(LibraryFilter.all)
                Label("Favorites", systemImage: "star").tag(LibraryFilter.favorites)
                Label("Mythic+", systemImage: "key").tag(LibraryFilter.kind(.mythicPlus))
                Label("Raid", systemImage: "shield.lefthalf.filled").tag(LibraryFilter.kind(.raidEncounter))
                Label("Dungeon", systemImage: "building.columns").tag(LibraryFilter.kind(.dungeonEncounter))
                Label("Delves", systemImage: "lamp.desk").tag(LibraryFilter.kind(.delve))
                Label("Arena", systemImage: "figure.fencing").tag(LibraryFilter.kind(.arena))
                Label("Clips", systemImage: "bookmark").tag(LibraryFilter.kind(.clip))
            }
            Section("Footage") {
                Label("Recent Sessions", systemImage: "film.stack").tag(LibraryFilter.footage)
            }
        }
        .safeAreaInset(edge: .bottom) {
            CaptureStatus()
                .padding(10)
        }
    }
}

private struct CaptureStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.captureState.isRecording ? .red : .secondary)
                .frame(width: 8, height: 8)
            Text(model.captureState.statusText)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

private struct ActivityList: View {
    let activities: [Activity]
    @Binding var selection: Activity.ID?
    @Environment(AppModel.self) private var model

    var body: some View {
        if activities.isEmpty {
            ContentUnavailableView(
                "No Activities Yet",
                systemImage: "record.circle",
                description: Text("Boss pulls, keys and arena matches show up here automatically while combat logging is on. Press \(Hotkey.bookmark.display) to bookmark a moment.")
            )
        } else {
            // Numbered across the whole library so filtering doesn't renumber pulls.
            let pullNumbers = ActivityPresentation.pullNumbers(model.activities)
            List(selection: $selection) {
                ForEach(groupedByDay, id: \.day) { group in
                    Section(group.day.formatted(date: .complete, time: .omitted)) {
                        ForEach(group.activities) { activity in
                            ActivityRow(activity: activity, gameData: model.gameData,
                                        pullNumber: pullNumbers[activity.id])
                                .tag(activity.id)
                                .contextMenu {
                                    Button(activity.isFavorite ? "Unfavorite" : "Favorite") { model.toggleFavorite(activity) }
                                    Divider()
                                    Button("Delete", role: .destructive) { model.delete(activity) }
                                }
                        }
                    }
                }
            }
            .onDeleteCommand {
                if let activity = activities.first(where: { $0.id == selection }) { model.delete(activity) }
            }
        }
    }

    private var groupedByDay: [(day: Date, activities: [Activity])] {
        let calendar = Calendar.current
        return Dictionary(grouping: activities) { calendar.startOfDay(for: $0.start) }
            .map { (day: $0.key, activities: $0.value) }
            .sorted { $0.day > $1.day }
    }
}

private struct ActivityRow: View {
    let activity: Activity
    let gameData: GameData
    let pullNumber: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: activity.kind.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(activity.title).fontWeight(.medium).lineLimit(1)
                    if activity.isFavorite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    }
                }
                Text(ActivityPresentation.caption(for: activity, gameData: gameData, pullNumber: pullNumber))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                ResultBadge(badge: ActivityPresentation.badge(for: activity, gameData: gameData))
                Text("\(activity.start.formatted(date: .omitted, time: .shortened)) · \(formatTime(activity.duration()))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help(ActivityPresentation.tooltip(for: activity, gameData: gameData))
    }
}

private struct ResultBadge: View {
    let badge: ActivityPresentation.Badge

    var body: some View {
        Text(badge.text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
    }

    private var color: Color {
        switch badge.tone {
        case .positive: .green
        case .negative: .red
        case .warning: .orange
        case .active: .blue
        case .neutral: .secondary
        }
    }
}

private struct SessionList: View {
    @Binding var selection: FootageSession.ID?
    @Environment(AppModel.self) private var model

    var body: some View {
        let sessions = model.sessions
        if sessions.isEmpty {
            ContentUnavailableView("No Footage", systemImage: "film.stack",
                                   description: Text("Footage is recorded whenever World of Warcraft is running."))
        } else {
            List(sessions, selection: $selection) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.start.formatted(date: .abbreviated, time: .shortened))
                        .fontWeight(.medium)
                    Text("\(formatTime(session.end.timeIntervalSince(session.start))) · \(session.segments.count) segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(session.id)
            }
        }
    }
}

extension ActivityKind {
    var symbol: String {
        switch self {
        case .mythicPlus: "key.fill"
        case .raidEncounter: "shield.lefthalf.filled"
        case .dungeonEncounter: "building.columns.fill"
        case .delve: "lamp.desk.fill"
        case .encounter: "flag.fill"
        case .arena: "figure.fencing"
        case .clip: "bookmark.fill"
        }
    }
}
