import Charts
import RecorderCore
import SwiftUI

/// Death recaps read from the combat log, kept so the Deaths list and a recap don't each read
/// the log again. Keyed by marker, which a clip shares with the activity it came from.
@MainActor
@Observable
final class DeathRecapStore {
    enum State {
        case loading
        case loaded(DeathRecap)
        case failed(String)
    }

    private var states: [Marker.ID: State] = [:]

    func state(for marker: Marker) -> State {
        states[marker.id] ?? .loading
    }

    /// Reads the recap unless it's loaded or loading. One that failed is tried again, e.g. after
    /// the WoW folder is fixed in Settings.
    func load(_ marker: Marker, model: AppModel) async {
        switch states[marker.id] {
        case .loaded, .loading: return
        case .failed, nil: break
        }
        states[marker.id] = .loading
        do {
            states[marker.id] = .loaded(try await model.deathRecap(for: marker))
        } catch {
            states[marker.id] = .failed(error.localizedDescription)
        }
    }
}

extension Marker {
    /// Who died, for a death marker: "You" or their name.
    var victimName: String {
        kind == .playerDeath ? "You" : label.replacingOccurrences(of: " died", with: "")
    }
}

/// What hit someone in the seconds before they died, in place of the side panel's tabs. It
/// follows the video: the hit on screen is highlighted and later ones are dimmed.
struct DeathRecapView: View {
    let death: PlaybackController.TimedMarker
    /// Every death in the item, for stepping to the previous or next one.
    let deaths: [PlaybackController.TimedMarker]
    let backTitle: String
    let playback: PlaybackController
    let recaps: DeathRecapStore
    let select: (PlaybackController.TimedMarker) -> Void
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @State private var showHealing = true

    private var marker: Marker { death.marker }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { close() } label: {
                    Label(backTitle, systemImage: "chevron.left")
                }
                .help("Back to the \(backTitle.lowercased())")
                Spacer()
                Toggle("Healing", isOn: $showHealing)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Show healing received")
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider()

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(marker.kind == .playerDeath ? "You died" : marker.label).font(.headline)
                    Spacer()
                    Text(formatTime(death.time))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if case .loaded(let recap) = recaps.state(for: marker) {
                    summary(recap)
                }
            }
            .padding([.horizontal, .top], 8)

            switch recaps.state(for: marker) {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .loaded(let recap):
                events(recap)
            }

            if deaths.count > 1 {
                Divider()
                footer
            }
        }
        .task(id: marker.id) { await recaps.load(marker, model: model) }
    }

    @ViewBuilder
    private func summary(_ recap: DeathRecap) -> some View {
        if let blow = recap.killingBlow {
            Text("Killed by \(blow.ability) from \(blow.source)")
                .fontWeight(.medium)
        }
        Text("Last \(Int(DeathRecap.window)) s: \(formatAmount(recap.damageTaken)) damage taken, \(formatAmount(recap.healingReceived)) healing")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func events(_ recap: DeathRecap) -> some View {
        let shown = recap.events.filter { showHealing || $0.kind != .heal }
        // Only follow the video while it's playing around this death.
        let now = playback.currentWallClock.flatMap { DeathRecap.follows($0, death: marker.date) ? $0 : nil }
        let current = now.flatMap { DeathRecap.latest(shown, at: $0) }

        return VStack(spacing: 0) {
            HealthChart(recap: recap, death: marker.date,
                        playhead: now.map { $0.timeIntervalSince(marker.date) },
                        seek: { offset in playback.seek(to: marker.date.addingTimeInterval(offset)) })
                .frame(height: 56)
                .padding(8)

            ScrollViewReader { proxy in
                List(shown.reversed()) { event in
                    Button {
                        playback.seek(to: event.date, leadIn: 1)
                        playback.play()
                    } label: {
                        RecapRow(event: event, death: marker.date)
                            .opacity(now.map { event.date > $0 } == true ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                    .id(event.id)
                    .listRowBackground(event.id == current?.id ? Color.accentColor.opacity(0.2) : nil)
                }
                .onChange(of: current?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private var footer: some View {
        let index = deaths.firstIndex { $0.id == death.id }
        let previous = index.flatMap { $0 > 0 ? deaths[$0 - 1] : nil }
        let next = index.flatMap { $0 + 1 < deaths.count ? deaths[$0 + 1] : nil }
        return HStack {
            if let previous {
                Button { select(previous) } label: {
                    Label("\(previous.marker.victimName) · \(formatTime(previous.time))", systemImage: "chevron.left")
                }
                .help("Previous death")
            }
            Spacer()
            if let next {
                Button { select(next) } label: {
                    HStack(spacing: 4) {
                        Text("\(next.marker.victimName) · \(formatTime(next.time))")
                        Image(systemName: "chevron.right")
                    }
                }
                .help("Next death")
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(8)
    }
}

/// Every death in the item as a card with its killing blow and health. Click one for its recap.
struct DeathList: View {
    let deaths: [PlaybackController.TimedMarker]
    let recaps: DeathRecapStore
    let open: (PlaybackController.TimedMarker) -> Void

    var body: some View {
        if deaths.isEmpty {
            ContentUnavailableView("No Deaths", systemImage: "heart", description: Text("Nobody died here."))
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(deaths) { death in
                        DeathCard(death: death, recaps: recaps) { open(death) }
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct DeathCard: View {
    let death: PlaybackController.TimedMarker
    let recaps: DeathRecapStore
    let open: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: death.marker.kind.symbol)
                        .foregroundStyle(death.marker.kind.color)
                    Text(death.marker.victimName).fontWeight(.semibold)
                    Spacer()
                    Text(formatTime(death.time))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                switch recaps.state(for: death.marker) {
                case .loading:
                    ProgressView().controlSize(.small)
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                case .loaded(let recap):
                    if let blow = recap.killingBlow {
                        Text("\(blow.ability) from \(blow.source)")
                            .font(.callout)
                            .lineLimit(1)
                    }
                    HealthChart(recap: recap, death: death.marker.date)
                        .frame(height: 28)
                    HStack(spacing: 10) {
                        Text("\(formatAmount(recap.damageTaken)) taken").foregroundStyle(.red)
                        Text("\(formatAmount(recap.healingReceived)) healed").foregroundStyle(.green)
                        Spacer()
                        Text("\(recap.events.count) events")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump here and show what led to this death")
        .task(id: death.id) { await recaps.load(death.marker, model: model) }
    }
}

/// Health over the recap's window, with ticks for hits (red) and heals (green). With `seek`,
/// clicking or dragging moves the video to that moment.
private struct HealthChart: View {
    let recap: DeathRecap
    let death: Date
    /// Where playback is, in seconds from the death.
    var playhead: Double?
    var seek: ((Double) -> Void)?

    private struct Point: Identifiable {
        var id: Int
        var offset: Double
        var percent: Double
    }

    private static let domain = -DeathRecap.window...0.5

    var body: some View {
        let points = recap.events.compactMap { event in
            event.healthPercent.map { Point(id: event.id, offset: event.date.timeIntervalSince(death), percent: $0) }
        }
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Seconds", point.offset), y: .value("Health", point.percent))
                    .foregroundStyle(.red.opacity(0.15))
                LineMark(x: .value("Seconds", point.offset), y: .value("Health", point.percent))
                    .foregroundStyle(.red)
            }
            ForEach(recap.events) { event in
                RuleMark(x: .value("Seconds", event.date.timeIntervalSince(death)), yStart: .value("Health", 0), yEnd: .value("Health", 10))
                    .foregroundStyle(event.kind == .heal ? .green : .red)
            }
            if let playhead {
                RuleMark(x: .value("Seconds", playhead))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXScale(domain: Self.domain)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            if let seek {
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard let plot = proxy.plotFrame else { return }
                            if let offset: Double = proxy.value(atX: value.location.x - geo[plot].origin.x) {
                                seek(min(max(offset, Self.domain.lowerBound), Self.domain.upperBound))
                            }
                        })
                }
            }
        }
        .help(seek == nil ? "" : "Health in the last \(Int(DeathRecap.window)) seconds. Click to see that moment.")
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
