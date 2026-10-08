import RecorderCore
import SwiftUI

enum SidebarItem: Hashable {
    case all
    case favorites
    case kind(ActivityKind)
    case footage
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var sidebar: SidebarItem = .all
    @State private var filter = ActivityFilter()
    @State private var selection: Set<Activity.ID> = []
    @State private var selectedSessionID: FootageSession.ID?
    /// Several activities waiting for the user to confirm their deletion.
    @State private var pendingDeletion: Set<Activity.ID> = []
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let section = sectionFilter.apply(model.activities, gameData: model.gameData)
        let shown = filter.isNarrowed ? effectiveFilter.apply(section, gameData: model.gameData) : section
        // Rows can leave the list while selected (unfavorited in Favorites, a note edited), so
        // only what's still shown counts as selected.
        let selected = selection.isEmpty ? [] : shown.filter { selection.contains($0.id) }
        NavigationSplitView {
            Sidebar(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            Group {
                if sidebar == .footage {
                    SessionList(selection: $selectedSessionID)
                } else {
                    ActivityList(activities: shown, section: section, filter: $filter, selection: $selection,
                                 onDelete: requestDelete)
                        .searchable(text: $filter.text, placement: .toolbar, prompt: "Titles, places and notes")
                        .searchFocused($isSearchFocused)
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            detail(selected: selected)
                .environment(\.allowsPlainKeyShortcuts, !isSearchFocused)
        }
        .onChange(of: filter) { pruneSelection() }
        .onChange(of: sidebar) { pruneSelection() }
        .confirmationDialog(
            "Delete \(pendingDeletion.count) activities?",
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }),
            presenting: pendingDeletion
        ) { ids in
            Button("Delete", role: .destructive) { delete(ids) }
        } message: { _ in
            Text("Their footage is cleaned up later, unless another activity or a clip still uses it.")
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
    private func detail(selected: [Activity]) -> some View {
        if sidebar == .footage {
            if let session = model.sessions.first(where: { $0.id == selectedSessionID }) {
                PlayerView(item: playbackItem(for: session))
            } else {
                ContentUnavailableView("Select a Session", systemImage: "film.stack",
                                       description: Text("Recent footage is kept for \(model.settings.keepUnmarkedHours) hours."))
            }
        } else {
            if selected.count > 1 {
                SelectionSummary(activities: selected, onDelete: requestDelete)
            } else if let activity = selected.first {
                PlayerView(item: PlaybackItem(
                    title: activity.title, start: activity.start, end: activity.end ?? .distantFuture,
                    markers: activity.markers, focus: focus(for: activity), activityID: activity.id))
            } else {
                ContentUnavailableView("Select an Activity", systemImage: "play.rectangle")
            }
        }
    }

    /// Bookmark clips open just before the first bookmark rather than 40 seconds earlier.
    private func focus(for activity: Activity) -> Date? {
        guard activity.kind == .clip,
              let bookmark = activity.markers.first(where: { $0.kind == .bookmark }) else { return nil }
        return bookmark.date.addingTimeInterval(-PlaybackController.markerLeadIn)
    }

    /// Just the sidebar's choice.
    private var sectionFilter: ActivityFilter {
        var section = ActivityFilter()
        switch sidebar {
        case .all, .footage: break
        case .favorites: section.favoritesOnly = true
        case .kind(let kind): section.kind = kind
        }
        return section
    }

    /// The sidebar's choice plus search and filters.
    private var effectiveFilter: ActivityFilter {
        var effective = filter
        effective.kind = sectionFilter.kind
        effective.favoritesOnly = sectionFilter.favoritesOnly
        return effective
    }

    /// Keeps only selected activities that are still shown, so bulk actions never touch hidden ones.
    private func pruneSelection() {
        guard !selection.isEmpty else { return }
        let shown = Set(effectiveFilter.apply(model.activities, gameData: model.gameData).map(\.id))
        selection.formIntersection(shown)
    }

    private func requestDelete(_ ids: Set<Activity.ID>) {
        if ids.count > 1 {
            pendingDeletion = ids
        } else {
            delete(ids)
        }
    }

    private func delete(_ ids: Set<Activity.ID>) {
        model.delete(ids)
        selection.subtract(ids)
        pendingDeletion = []
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
    @Binding var selection: SidebarItem
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: $selection) {
            Section("Activities") {
                Label("All", systemImage: "tray.full").tag(SidebarItem.all)
                Label("Favorites", systemImage: "star").tag(SidebarItem.favorites)
                Label("Mythic+", systemImage: "key").tag(SidebarItem.kind(.mythicPlus))
                Label("Raid", systemImage: "shield.lefthalf.filled").tag(SidebarItem.kind(.raidEncounter))
                Label("Dungeon", systemImage: "building.columns").tag(SidebarItem.kind(.dungeonEncounter))
                Label("Delves", systemImage: "lamp.desk").tag(SidebarItem.kind(.delve))
                Label("Arena", systemImage: "figure.fencing").tag(SidebarItem.kind(.arena))
                Label("Clips", systemImage: "bookmark").tag(SidebarItem.kind(.clip))
            }
            Section("Footage") {
                Label("Recent Sessions", systemImage: "film.stack").tag(SidebarItem.footage)
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
    /// What the search and filters let through.
    let activities: [Activity]
    /// Everything in the sidebar section, before search and filters.
    let section: [Activity]
    @Binding var filter: ActivityFilter
    @Binding var selection: Set<Activity.ID>
    let onDelete: (Set<Activity.ID>) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.activities.isEmpty {
            ContentUnavailableView(
                "No Activities Yet",
                systemImage: "record.circle",
                description: Text("Boss pulls, keys and arena matches show up here automatically while combat logging is on. Press \(Hotkey.bookmark.display) to bookmark a moment.")
            )
        } else {
            VStack(spacing: 0) {
                LibraryFilterBar(filter: $filter, activities: section, shownCount: activities.count)
                Divider()
                if activities.isEmpty {
                    ContentUnavailableView {
                        Label("No Matches", systemImage: "magnifyingglass")
                    } description: {
                        Text(filter.isNarrowed ? "Nothing here matches your search and filters." : "Nothing here yet.")
                    } actions: {
                        if filter.isNarrowed {
                            Button("Clear Filters") { filter.clear() }
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
        }
    }

    private var list: some View {
        // Numbered across the whole library so filtering doesn't renumber pulls.
        let pullNumbers = ActivityPresentation.pullNumbers(model.activities)
        return List(selection: $selection) {
            ForEach(groupedByDay, id: \.day) { group in
                Section(group.day.formatted(date: .complete, time: .omitted)) {
                    ForEach(group.activities) { activity in
                        ActivityRow(activity: activity, gameData: model.gameData,
                                    pullNumber: pullNumbers[activity.id])
                            .tag(activity.id)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: Activity.ID.self) { ids in
            menu(for: ids)
        }
        .onDeleteCommand {
            let ids = Set(activities.lazy.map(\.id).filter(selection.contains))
            if !ids.isEmpty { onDelete(ids) }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<Activity.ID>) -> some View {
        let chosen = activities.filter { ids.contains($0.id) }
        let count = chosen.count > 1 ? " \(chosen.count) Activities" : ""
        if chosen.contains(where: { !$0.isFavorite }) {
            Button("Favorite\(count)") { model.setFavorite(true, for: ids) }
        }
        if chosen.contains(where: \.isFavorite) {
            Button("Unfavorite\(count)") { model.setFavorite(false, for: ids) }
        }
        if !chosen.isEmpty {
            Divider()
            Button("Delete\(count)\(chosen.count > 1 ? "…" : "")", role: .destructive) { onDelete(ids) }
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
            ActivityThumbnail(activity: activity)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(activity.title).fontWeight(.medium).lineLimit(1)
                    if activity.isFavorite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    }
                    if activity.notes != nil {
                        Image(systemName: "note.text").font(.caption).foregroundStyle(.secondary)
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

/// A still from the activity, made the first time its row is shown with the library frontmost.
private struct ActivityThumbnail: View {
    let activity: Activity
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?

    private struct Request: Equatable {
        var id: Activity.ID
        var isFinished: Bool
        /// Retries when new footage lands, in case this activity's last minute was still recording.
        var footage: Int
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: activity.kind.symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(.rect(cornerRadius: 4))
        .task(id: Request(id: activity.id, isFinished: !activity.isInProgress,
                          footage: image == nil ? model.segments.count : 0)) {
            guard image == nil else { return }
            let made = await model.thumbnail(for: activity)
            if !Task.isCancelled { image = made }
        }
    }
}

/// Shown instead of the player when several activities are selected.
private struct SelectionSummary: View {
    let activities: [Activity]
    let onDelete: (Set<Activity.ID>) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = Set(activities.map(\.id))
        let favorites = activities.filter(\.isFavorite).count
        let duration = activities.reduce(0) { $0 + $1.duration() }
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("\(activities.count) Activities Selected")
                .font(.title2.weight(.semibold))
            Text("\(formatTime(duration)) in total" + (favorites > 0 ? " · \(favorites) favorite\(favorites == 1 ? "" : "s")" : ""))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Favorite", systemImage: "star") { model.setFavorite(true, for: ids) }
                    .disabled(favorites == activities.count)
                Button("Unfavorite", systemImage: "star.slash") { model.setFavorite(false, for: ids) }
                    .disabled(favorites == 0)
                Button("Delete…", systemImage: "trash", role: .destructive) { onDelete(ids) }
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
