import RecorderCore
import SwiftUI

/// Filter buttons above the activity list. Each opens a small popover; a set filter shows its
/// value in the accent colour.
struct LibraryFilterBar: View {
    @Binding var filter: ActivityFilter
    /// Activities in the current sidebar section, to offer choices from.
    let activities: [Activity]
    let shownCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                FilterChip(title: "Boss or Dungeon", value: placeLabel) { close in
                    PlaceOptions(place: $filter.place, activities: activities, close: close)
                }
                FilterChip(title: "Result", value: resultLabel) { _ in
                    ResultOptions(outcomes: $filter.outcomes)
                }
                if hasKeys || filter.minKeyLevel != nil || filter.maxKeyLevel != nil {
                    FilterChip(title: "Key Level", value: keyLevelLabel) { _ in
                        KeyLevelOptions(filter: $filter, activities: activities)
                    }
                }
                FilterChip(title: "Date", value: dateLabel) { close in
                    DateOptions(filter: $filter, activities: activities, close: close)
                }
                if hasSeveralCharacters || filter.character != nil {
                    FilterChip(title: "Character", value: filter.character) { close in
                        CharacterOptions(character: $filter.character, activities: activities, close: close)
                    }
                }
            }
            if filter.isNarrowed {
                HStack {
                    Text(shownCount == 1 ? "1 activity" : "\(shownCount) activities")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Filters") { filter.clear() }
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // Cheap checks, so the bar doesn't scan the whole library on every update.
    private var hasKeys: Bool { activities.contains { $0.keystoneLevel != nil } }

    private var hasSeveralCharacters: Bool {
        guard let first = activities.lazy.compactMap(\.character).first else { return false }
        return activities.contains { $0.character != nil && $0.character != first }
    }

    private var placeLabel: String? {
        switch filter.place {
        case .instance(let name)?: name
        case .boss(let id)?: activities.first { $0.encounterID == id }?.title ?? "Boss"
        case nil: nil
        }
    }

    private var resultLabel: String? {
        let chosen = ActivityFilter.Outcome.allCases.filter(filter.outcomes.contains)
        switch chosen.count {
        case 0: return nil
        case 1, 2: return chosen.map(\.displayName).joined(separator: ", ")
        default: return "\(chosen.count) results"
        }
    }

    private var keyLevelLabel: String? {
        switch (filter.minKeyLevel, filter.maxKeyLevel) {
        case let (low?, high?): low == high ? "+\(low)" : "+\(low) to +\(high)"
        case let (low?, nil): "+\(low) and up"
        case let (nil, high?): "Up to +\(high)"
        case (nil, nil): nil
        }
    }

    private var dateLabel: String? {
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if let preset = ActivityFilter.DatePreset.allCases.first(where: { filter.isShowing($0) }) {
            return preset.displayName
        }
        switch (filter.fromDay, filter.toDay) {
        case let (from?, to?):
            return Calendar.current.isDate(from, inSameDayAs: to)
                ? from.formatted(format) : "\(from.formatted(format)) – \(to.formatted(format))"
        case let (from?, nil): return "Since \(from.formatted(format))"
        case let (nil, to?): return "Until \(to.formatted(format))"
        case (nil, nil): return nil
        }
    }
}

extension ActivityFilter {
    func isShowing(_ preset: DatePreset) -> Bool {
        guard let fromDay, let toDay else { return false }
        let days = preset.days()
        let calendar = Calendar.current
        return calendar.isDate(fromDay, inSameDayAs: days.from) && calendar.isDate(toDay, inSameDayAs: days.to)
    }

    mutating func showDays(_ preset: DatePreset?) {
        let days = preset?.days()
        fromDay = days?.from
        toDay = days?.to
    }
}

// MARK: - Chip

private struct FilterChip<Options: View>: View {
    let title: String
    let value: String?
    @ViewBuilder let options: (_ close: @escaping () -> Void) -> Options
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(value ?? title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(value == nil ? .regular : .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(value == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            .background(value == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint.opacity(0.18)), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(value.map { "\(title): \($0)" } ?? title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            options { isPresented = false }
        }
    }
}

// MARK: - Options

private let optionRowHeight: CGFloat = 22

/// A checkmarked row in an option list.
private struct OptionRow: View {
    let title: String
    let isSelected: Bool
    var indent: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(indent ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .padding(.leading, indent ? 18 : 0)
            .padding(.horizontal, 6)
            .frame(height: optionRowHeight)
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 4))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct OptionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: optionRowHeight, alignment: .bottom)
    }
}

/// A scrolling list sized to its rows, up to a limit. (Popovers don't size scroll views well.)
private struct OptionList<Content: View>: View {
    let rows: Int
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(6)
        }
        .frame(width: 260, height: min(CGFloat(rows) * optionRowHeight + 12, 420))
    }
}

private struct PlaceOptions: View {
    @Binding var place: ActivityFilter.Place?
    let activities: [Activity]
    let close: () -> Void

    var body: some View {
        let facets = LibraryFacets(activities)
        let groups = LibraryFacets.Group.allCases.map { group in
            (group: group, instances: facets.instances.filter { $0.group == group })
        }.filter { !$0.instances.isEmpty }
        let rows = 1 + groups.reduce(0) { $0 + 1 + $1.instances.reduce(0) { $0 + 1 + $1.bosses.count } }
            + (facets.otherBosses.isEmpty ? 0 : 1 + facets.otherBosses.count)

        OptionList(rows: rows) {
            option("Any boss or dungeon", nil)
            ForEach(groups, id: \.group) { group in
                OptionHeader(title: group.group.displayName)
                ForEach(group.instances) { instance in
                    option(instance.name, .instance(instance.name))
                    ForEach(instance.bosses) { boss in
                        option(boss.name, .boss(encounterID: boss.id), indent: true)
                    }
                }
            }
            if !facets.otherBosses.isEmpty {
                OptionHeader(title: "Other Bosses")
                ForEach(facets.otherBosses) { boss in
                    option(boss.name, .boss(encounterID: boss.id))
                }
            }
        }
    }

    private func option(_ title: String, _ value: ActivityFilter.Place?, indent: Bool = false) -> some View {
        OptionRow(title: title, isSelected: place == value, indent: indent) {
            place = value
            close()
        }
    }
}

private struct CharacterOptions: View {
    @Binding var character: String?
    let activities: [Activity]
    let close: () -> Void

    var body: some View {
        let characters = LibraryFacets(activities).characters
        OptionList(rows: characters.count + 1) {
            option("Any character", nil)
            ForEach(characters, id: \.self) { option($0, $0) }
        }
    }

    private func option(_ title: String, _ value: String?) -> some View {
        OptionRow(title: title, isSelected: character == value) {
            character = value
            close()
        }
    }
}

private struct ResultOptions: View {
    @Binding var outcomes: Set<ActivityFilter.Outcome>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ActivityFilter.Outcome.allCases) { outcome in
                Toggle(outcome.displayName, isOn: Binding(
                    get: { outcomes.contains(outcome) },
                    set: { isOn in
                        if isOn { outcomes.insert(outcome) } else { outcomes.remove(outcome) }
                    }))
            }
            Text("Timed and Depleted are for keys and need\nthe helper addon's timers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .toggleStyle(.checkbox)
        .padding(12)
    }
}

private struct KeyLevelOptions: View {
    @Binding var filter: ActivityFilter
    let activities: [Activity]

    var body: some View {
        let levels = availableLevels
        Form {
            Picker("From", selection: $filter.minKeyLevel) {
                Text("Any").tag(Int?.none)
                ForEach(levels, id: \.self) { Text("+\($0)").tag(Int?.some($0)) }
            }
            Picker("To", selection: $filter.maxKeyLevel) {
                Text("Any").tag(Int?.none)
                ForEach(levels, id: \.self) { Text("+\($0)").tag(Int?.some($0)) }
            }
        }
        .frame(width: 160)
        .padding(12)
    }

    /// The levels in the library, plus whatever is already chosen.
    private var availableLevels: [Int] {
        let known = LibraryFacets(activities).keyLevels
        let values = [known?.lowerBound, known?.upperBound, filter.minKeyLevel, filter.maxKeyLevel].compactMap { $0 }
        guard let low = values.min(), let high = values.max() else { return [] }
        return Array(low...high)
    }
}

private struct DateOptions: View {
    @Binding var filter: ActivityFilter
    let activities: [Activity]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                OptionRow(title: "Any time", isSelected: filter.fromDay == nil && filter.toDay == nil) {
                    filter.showDays(nil)
                    close()
                }
                ForEach(ActivityFilter.DatePreset.allCases) { preset in
                    OptionRow(title: preset.displayName, isSelected: filter.isShowing(preset)) {
                        filter.showDays(preset)
                        close()
                    }
                }
            }
            Divider()
            Form {
                DatePicker("From", selection: Binding(
                    get: { filter.fromDay ?? oldestDay },
                    set: { filter.fromDay = $0 }), displayedComponents: .date)
                DatePicker("To", selection: Binding(
                    get: { filter.toDay ?? Date() },
                    set: { filter.toDay = $0 }), displayedComponents: .date)
            }
            .datePickerStyle(.field)
        }
        .frame(width: 200)
        .padding(10)
    }

    private var oldestDay: Date {
        activities.map(\.start).min() ?? Date()
    }
}

// MARK: - Layout

/// Lays views out left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.last.map { $0.frame.maxX } ?? 0 }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: rows.last?.map(\.frame.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                                           proposal: ProposedViewSize(item.frame.size))
            }
        }
    }

    private struct Item {
        var index: Int
        var frame: CGRect
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [[Item]] {
        var rows: [[Item]] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            if x == 0 { rows.append([]) }
            rows[rows.count - 1].append(Item(index: index, frame: CGRect(origin: CGPoint(x: x, y: y), size: size)))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return rows
    }
}
