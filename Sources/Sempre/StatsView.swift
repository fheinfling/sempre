import SwiftUI
import SempreCore
import Charts

enum Period: String, CaseIterable { case week = "Week", month = "Month", year = "Year", all = "All" }

/// One coloured share of the total: a project, or a subproject when filtered to one project.
struct Slice: Identifiable {
    let id: UUID
    let name: String
    let color: Color
    let time: TimeInterval
}

struct StatsView: View {
    @EnvironmentObject var store: Store
    @State private var period: Period
    @State private var offset = 0
    @State private var projectID: UUID?
    @State private var confirmDelete: UUID?

    init(period: Period = .week, projectID: UUID? = nil) {
        _period = State(initialValue: period)
        _projectID = State(initialValue: projectID)
    }

    private var cal: Calendar { Calendar.current }

    private var interval: DateInterval {
        switch period {
        case .all:
            let start = cal.dateInterval(of: .year, for: store.firstEntryStart)!.start
            return DateInterval(start: start, end: cal.dateInterval(of: .year, for: store.now)!.end)
        default:
            let comp: Calendar.Component = period == .week ? .weekOfYear : period == .month ? .month : .year
            let ref = cal.date(byAdding: comp, value: offset, to: store.now)!
            return cal.dateInterval(of: comp, for: ref)!
        }
    }

    /// Chart bucket size for the period.
    private var bucket: Calendar.Component {
        switch period {
        case .week, .month: .day
        case .year: .month
        case .all: .year
        }
    }

    private var title: String {
        let iv = interval
        let end = iv.end.addingTimeInterval(-1)
        switch period {
        case .week: return "\(iv.start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month: return iv.start.formatted(.dateTime.month(.wide).year())
        case .year: return iv.start.formatted(.dateTime.year())
        case .all: return "\(iv.start.formatted(.dateTime.year())) – \(end.formatted(.dateTime.year()))"
        }
    }

    private func slices(in iv: DateInterval) -> [Slice] {
        var map: [UUID?: TimeInterval] = [:]
        for e in store.library.entries {
            if let projectID, e.projectID != projectID { continue }
            let d = e.duration(in: iv, now: store.now)
            if d > 0 { map[projectID == nil ? e.projectID : e.subprojectID, default: 0] += d }
        }
        if let projectID, let p = store.project(projectID) {
            // Subprojects get the palette in order of size; untagged time keeps the project colour.
            let sorted = map.sorted { $0.value > $1.value }
            return sorted.enumerated().map { i, kv in
                if let sid = kv.key, let s = store.subproject(sid) {
                    return Slice(id: sid, name: s.name, color: Palette.color(i + p.color + 1), time: kv.value)
                }
                return Slice(id: p.id, name: "No subproject", color: p.swatch, time: kv.value)
            }
        }
        return map.compactMap { id, t in
            id.flatMap { store.project($0) }.map { Slice(id: $0.id, name: $0.name, color: $0.swatch, time: t) }
        }
        .sorted { $0.time > $1.time }
    }

    private struct Bar: Identifiable {
        let id = UUID()
        let date: Date
        let color: Color
        let hours: Double
    }

    private func bars(_ iv: DateInterval, colors: [UUID: Color]) -> [Bar] {
        var result: [Bar] = []
        var d = iv.start
        while d < iv.end {
            let next = cal.date(byAdding: bucket, value: 1, to: d)!
            for s in slices(in: DateInterval(start: d, end: next)) {
                result.append(Bar(date: d, color: colors[s.id] ?? s.color, hours: s.time / 3600))
            }
            d = next
        }
        return result
    }

    /// The week chart leaves out the weekend unless something was tracked on it.
    private func chartRange(_ iv: DateInterval, bars: [Bar]) -> DateInterval {
        guard period == .week, !bars.contains(where: { cal.isDateInWeekend($0.date) }) else { return iv }
        var start = iv.start, end = iv.end
        while start < end, cal.isDateInWeekend(start) { start = cal.date(byAdding: .day, value: 1, to: start)! }
        while end > start, cal.isDateInWeekend(end.addingTimeInterval(-1)) { end = cal.date(byAdding: .day, value: -1, to: end)! }
        return DateInterval(start: start, end: end)
    }

    /// Starts of months that fall inside the week chart (a week spanning two months), for a divider.
    private func monthStarts(in iv: DateInterval) -> [Date] {
        guard period == .week else { return [] }
        var result: [Date] = []
        var d = cal.dateInterval(of: .month, for: iv.start)!.end
        while d < iv.end {
            result.append(d)
            d = cal.date(byAdding: .month, value: 1, to: d)!
        }
        return result
    }

    /// Entries behind one breakdown row: a project, or a subproject (or untagged time) of the filtered project.
    private func entryIDs(of slice: Slice, in iv: DateInterval) -> Set<UUID> {
        Set(store.library.entries.filter { e in
            guard e.span(in: iv, now: store.now) > 0 else { return false }
            if let projectID {
                return e.projectID == projectID && (e.subprojectID ?? projectID) == slice.id
            }
            return e.projectID == slice.id
        }.map(\.id))
    }

    /// Distinct calendar days with any tracked time in the interval (respects the project filter).
    private func daysWorked(in iv: DateInterval) -> Int {
        var days = Set<Date>()
        for e in store.library.entries {
            if let projectID, e.projectID != projectID { continue }
            guard e.duration(in: iv, now: store.now) > 0 else { continue }
            days.insert(cal.startOfDay(for: max(e.start, iv.start)))
        }
        return days.count
    }

    var body: some View {
        let iv = interval
        let slices = slices(in: iv)
        let total = slices.reduce(0) { $0 + $1.time }
        let colors = Dictionary(slices.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        let bars = bars(iv, colors: colors)
        let peak = Dictionary(grouping: bars, by: \.date).values.map { $0.reduce(0) { $0 + $1.hours } }.max() ?? 0
        let days = daysWorked(in: iv)
        let shown = chartRange(iv, bars: bars)

        VStack(alignment: .leading, spacing: 12) {
            Segmented(options: Period.allCases, selection: $period) { $0.rawValue }
                .onChange(of: period) { offset = 0; confirmDelete = nil }

            HStack {
                projectPicker
                Spacer()
                if period != .all {
                    Button { offset -= 1 } label: { Image(systemName: "chevron.left") }
                    Button { offset = 0 } label: { Image(systemName: "circle.fill").font(.system(size: 5)) }
                        .disabled(offset == 0)
                    Button { offset += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(offset >= 0)
                }
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(Fmt.short(total))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if days > 0 {
                    Text("\(days) \(days == 1 ? "day" : "days") worked · ⌀ \(Fmt.short(total / Double(days))) per day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Chart {
                ForEach(bars) { b in
                    BarMark(x: .value("Date", b.date, unit: bucket), y: .value("Hours", b.hours))
                        .foregroundStyle(b.color)
                        .cornerRadius(2)
                }
                ForEach(monthStarts(in: shown), id: \.self) { d in
                    RuleMark(x: .value("Month", d))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text(d.formatted(.dateTime.month(.abbreviated)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartXAxis {
                switch period {
                case .week:
                    AxisMarks(values: .stride(by: .day)) { v in
                        AxisValueLabel(centered: true) {
                            if let d = v.as(Date.self) {
                                VStack(spacing: 1) {
                                    Text(d.formatted(.dateTime.weekday(.narrow)))
                                    Text("\(cal.component(.day, from: d)).").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                case .month:
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.day())
                    }
                case .year:
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                    }
                case .all:
                    AxisMarks(values: .stride(by: .year, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.year(.twoDigits))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine()
                    AxisValueLabel { if let h = v.as(Double.self) { Text(Fmt.axis(h)) } }
                }
            }
            .chartXScale(domain: shown.start...shown.end)
            // Day buckets: at least a 1h scale so a few minutes don't fill the chart.
            .chartYScale(domain: 0...max(bucket == .day ? 1 : 0.1, peak * 1.1))
            .frame(height: 120)

            if slices.isEmpty {
                Text("No time tracked in this period.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                Scrollable(when: slices.count > 5, height: 180) {
                    VStack(spacing: 10) {
                        ForEach(slices) { s in
                            let ids = entryIDs(of: s, in: iv)
                            if confirmDelete == s.id {
                                HStack {
                                    Text("Delete \(ids.count) \(ids.count == 1 ? "entry" : "entries") of \(s.name)?")
                                        .font(.callout)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("Cancel") { confirmDelete = nil }
                                    Button("Delete") { store.deleteEntries(ids); confirmDelete = nil }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.red)
                                }
                                .controlSize(.small)
                                .padding(.vertical, 4)
                            } else {
                                BreakdownRow(name: s.name, color: s.color, time: s.time, share: total > 0 ? s.time / total : 0)
                                    .contentShape(Rectangle())
                                    .onTapGesture { projectID = projectID == nil ? s.id : nil }
                                    .contextMenu {
                                        if projectID == nil {
                                            Button("Show Entries") { projectID = s.id }
                                        }
                                        Button("Delete \(ids.count) \(ids.count == 1 ? "Entry" : "Entries") in This Period…", role: .destructive) {
                                            confirmDelete = s.id
                                        }
                                    }
                            }
                        }
                    }
                }
            }

            if let projectID, let project = store.project(projectID) {
                EntryList(project: project, interval: iv)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var projectPicker: some View {
        Menu {
            Button("All projects") { projectID = nil }
            Divider()
            ForEach(store.allProjects) { p in
                Button(p.archived ? "\(p.name) (archived)" : p.name) { projectID = p.id }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(projectID.flatMap { store.project($0)?.swatch } ?? Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(projectID.flatMap { store.project($0)?.name } ?? "All projects")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .font(.callout.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct BreakdownRow: View {
    let name: String
    let color: Color
    let time: TimeInterval
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name).lineLimit(1)
                Spacer()
                Text(Fmt.short(time)).monospacedDigit()
                Text("\(Int((share * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .font(.callout)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color).frame(width: max(4, geo.size.width * share))
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: - Entries

/// Time entries of one project in the selected period, each editable in place.
struct EntryList: View {
    @EnvironmentObject var store: Store
    let project: Project
    let interval: DateInterval
    @State private var editing: UUID?
    @State private var adding = false
    @State private var limit = 30
    @State private var confirmDelete: UUID?

    var body: some View {
        let entries = store.entries(of: project.id, in: interval)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Entries").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button { adding = true; editing = nil } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            Scrollable(when: entries.count > 5 || adding || editing != nil, height: 240) {
                VStack(spacing: 2) {
                    if adding {
                        EntryEditor(project: project, entry: nil) { adding = false }
                    }
                    ForEach(entries.prefix(limit)) { e in
                        if editing == e.id {
                            EntryEditor(project: project, entry: e) { editing = nil }
                        } else if confirmDelete == e.id {
                            HStack {
                                Text("Delete \(e.start.formatted(.dateTime.day().month(.abbreviated))), \(Fmt.short(e.worked(now: store.now)))?")
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                                Button("Cancel") { confirmDelete = nil }
                                Button("Delete") { store.deleteEntry(e.id); confirmDelete = nil }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.red)
                            }
                            .controlSize(.small)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                        } else {
                            EntryRow(entry: e)
                                .onTapGesture { editing = e.id; adding = false; confirmDelete = nil }
                                .contextMenu {
                                    Button("Edit Entry") { editing = e.id; adding = false }
                                    Button("Delete Entry…", role: .destructive) { confirmDelete = e.id; editing = nil }
                                }
                        }
                    }
                    if entries.count > limit {
                        Button("Show \(min(30, entries.count - limit)) more") { limit += 30 }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }
}

struct EntryRow: View {
    @EnvironmentObject var store: Store
    let entry: Entry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year(.twoDigits)))
                    .font(.callout)
                if let sub = store.subproject(entry.subprojectID) {
                    Text(sub.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text("\(entry.start.formatted(date: .omitted, time: .shortened)) – \(entry.end?.formatted(date: .omitted, time: .shortened) ?? "now")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.short(entry.worked(now: store.now)))
                    .font(.callout)
                    .monospacedDigit()
                if entry.breakTotal > 0 {
                    Text("−\(Fmt.short(entry.breakTotal)) break")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Inline editor for an existing entry, or a new one when `entry` is nil.
struct EntryEditor: View {
    @EnvironmentObject var store: Store
    let project: Project
    let entry: Entry?
    let done: () -> Void

    @State private var start = Date()
    @State private var end = Date()
    @State private var subprojectID: UUID?
    @State private var breaks: [Break] = []
    @State private var loaded = false
    @State private var confirmDelete = false

    private var isRunning: Bool { entry != nil && entry?.end == nil }
    private var span: TimeInterval { (isRunning ? Date() : end).timeIntervalSince(start) }
    private var breaksFit: Bool { breaks.reduce(0) { $0 + $1.duration } < span }
    private var valid: Bool { (isRunning ? start < Date() : end > start) && breaksFit }
    private var problem: String {
        if isRunning && start >= Date() { return "Start can't be in the future." }
        if !isRunning && end <= start { return "End must be after start." }
        return "Breaks are longer than the entry."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tapping the header folds the editor back into its row.
            HStack {
                Text(entry.map { $0.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? "New entry")
                    .font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "chevron.up").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: done)
            .help("Close")
            row("Start") { DatePicker("", selection: $start).labelsHidden() }
            row("End") {
                if isRunning {
                    Text("Running").foregroundStyle(.secondary)
                } else {
                    DatePicker("", selection: $end).labelsHidden()
                }
            }
            let subs = store.subprojects(of: project.id)
            if !subs.isEmpty || subprojectID != nil {
                row("Sub") {
                    Picker("", selection: $subprojectID) {
                        Text("None").tag(UUID?.none)
                        ForEach(subs) { Text($0.name).tag(UUID?.some($0.id)) }
                        if let id = subprojectID, !subs.contains(where: { $0.id == id }), let s = store.subproject(id) {
                            Text(s.name).tag(UUID?.some(id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }
            row("Break") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach($breaks) { $b in
                        BreakEditor(brk: $b, anchor: start) { breaks.removeAll { $0.id == b.id } }
                    }
                    Button {
                        breaks.append(Break(start: nil, duration: 30 * 60))
                    } label: {
                        Label(breaks.isEmpty ? "Add break" : "Add another", systemImage: "cup.and.saucer")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            HStack {
                if entry != nil {
                    if confirmDelete {
                        Button("Delete entry") { store.deleteEntry(entry!.id); done() }
                            .buttonStyle(.borderedProminent).tint(.red)
                    } else {
                        Button { confirmDelete = true } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete entry")
                    }
                }
                Spacer()
                Button("Cancel", action: done)
                    .keyboardShortcut(.cancelAction)
                Button(entry == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(project.swatch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
            .controlSize(.small)
            if !valid {
                Text(problem)
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(project.swatch.opacity(0.10)))
        .onAppear(perform: load)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let entry {
            start = entry.start
            end = entry.end ?? Date()
            subprojectID = entry.subprojectID
            breaks = entry.breaks ?? []
        } else {
            end = Date()
            start = end.addingTimeInterval(-3600)
        }
    }

    private func save() {
        if let entry {
            store.updateEntry(entry.id, start: start, end: isRunning ? nil : end, subprojectID: subprojectID, breaks: breaks)
        } else {
            store.addEntry(projectID: project.id, subprojectID: subprojectID, start: start, end: end, breaks: breaks)
        }
        done()
    }
}

/// One break: a length in minutes, or from–to times on the entry's day.
struct BreakEditor: View {
    @Binding var brk: Break
    let anchor: Date
    let remove: () -> Void

    private var timed: Binding<Bool> {
        Binding(
            get: { brk.start != nil },
            set: { on in
                // Switching to exact time places the break at noon of the entry's day (or its start, if later).
                let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: anchor) ?? anchor
                brk.start = on ? max(noon, anchor) : nil
            }
        )
    }

    private var minutes: Binding<Int> {
        Binding(get: { Int(brk.duration / 60) }, set: { brk.duration = TimeInterval(max(1, $0) * 60) })
    }

    private var from: Binding<Date> {
        Binding(get: { brk.start ?? anchor }, set: { brk.start = $0 })
    }

    private var to: Binding<Date> {
        Binding(
            get: { (brk.start ?? anchor).addingTimeInterval(brk.duration) },
            set: { brk.duration = max(60, $0.timeIntervalSince(brk.start ?? anchor)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Picker("", selection: timed) {
                    Text("Length").tag(false)
                    Text("Time").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .help("Remove break")
            }
            HStack(spacing: 6) {
                if brk.start == nil {
                    TextField("", value: minutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                    Stepper("", value: minutes, in: 1...600, step: 5).labelsHidden()
                    Text("min").font(.caption).foregroundStyle(.secondary)
                } else {
                    DatePicker("", selection: from, displayedComponents: .hourAndMinute).labelsHidden()
                    Text("–").foregroundStyle(.secondary)
                    DatePicker("", selection: to, displayedComponents: .hourAndMinute).labelsHidden()
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}
