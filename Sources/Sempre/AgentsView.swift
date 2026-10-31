import SwiftUI
import SempreCore

enum AgentPeriod: String, CaseIterable { case day = "Day", week = "Week", month = "Month", year = "Year" }

extension AgentKind {
    var color: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.40, green: 0.62, blue: 0.85)
        }
    }
}

/// What Claude Code and Codex worked on, and for how long, read from their session transcripts.
/// Not tied to Sempre's projects (yet): an agent's "project" is the repository it ran in.
struct AgentsView: View {
    @EnvironmentObject var agents: AgentTracker
    @State private var period: AgentPeriod
    @State private var offset = 0
    @State private var expanded: Set<String> = []

    /// Fixed, so switching periods doesn't resize the panel.
    private static let listHeight: CGFloat = 230
    private static let workingRows = 3

    init(period: AgentPeriod = .day) {
        _period = State(initialValue: period)
    }

    var body: some View {
        // Ticks every second so the time of agents working right now runs on between scans.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .onAppear { agents.refresh() }
    }

    private var component: Calendar.Component {
        switch period {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    private func interval(now: Date) -> DateInterval {
        let cal = Calendar.current
        return cal.dateInterval(of: component, for: cal.date(byAdding: component, value: offset, to: now)!)!
    }

    private func title(_ iv: DateInterval) -> String {
        let end = iv.end.addingTimeInterval(-1)
        switch period {
        case .day:
            let day = iv.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
            return offset == 0 ? "Today, \(day)" : offset == -1 ? "Yesterday, \(day)" : day
        case .week: return "\(iv.start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month: return iv.start.formatted(.dateTime.month(.wide).year())
        case .year: return iv.start.formatted(.dateTime.year())
        }
    }

    private struct Repo: Identifiable {
        let id: String
        let sessions: [(session: AgentSession, time: TimeInterval)]
        var time: TimeInterval { sessions.reduce(0) { $0 + $1.time } }
        func time(of kind: AgentKind) -> TimeInterval { sessions.filter { $0.session.kind == kind }.reduce(0) { $0 + $1.time } }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let iv = interval(now: now)
        // Sessions under a minute are mostly quick questions and checks.
        let timed = agents.sessions.map { ($0, $0.time(in: iv, now: now)) }.filter { $0.1 >= 60 }
        let groups = Dictionary(grouping: timed) { $0.0.project }
            .map { Repo(id: $0.key, sessions: $0.value.sorted { $0.1 > $1.1 }) }
            .sorted { $0.time > $1.time }
        let total = groups.reduce(0) { $0 + $1.time }
        let working = agents.sessions.filter(\.working)

        VStack(alignment: .leading, spacing: 12) {
            Segmented(options: AgentPeriod.allCases, selection: $period) { $0.rawValue }
                .onChange(of: period) { offset = 0; expanded = [] }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title(iv)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Button { offset -= 1 } label: { Image(systemName: "chevron.left") }
                        Button { offset = 0 } label: { Image(systemName: "circle.fill").font(.system(size: 5)) }
                            .disabled(offset == 0)
                        Button { offset += 1 } label: { Image(systemName: "chevron.right") }
                            .disabled(offset >= 0)
                    }
                    .buttonStyle(.borderless)
                }
                Text(Fmt.short(total))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                // Always there (if empty), so the layout below doesn't move.
                Text(timed.isEmpty ? " " : summary(sessions: timed.count, groups: groups))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !working.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    header("Working now")
                    Scrollable(when: working.count > Self.workingRows, height: CGFloat(Self.workingRows) * 46) {
                        VStack(spacing: 4) {
                            ForEach(working) { WorkingRow(session: $0, now: now) }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                header("Projects")
                ScrollView {
                    if !agents.loaded {
                        placeholder {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Reading agent sessions…")
                            }
                        }
                    } else if groups.isEmpty {
                        placeholder {
                            VStack(spacing: 4) {
                                Text("No agent work in this \(period == .day ? "day" : period.rawValue.lowercased())")
                                Text("Sempre reads the session logs Claude Code and Codex keep in ~/.claude and ~/.codex.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    } else {
                        VStack(spacing: 2) {
                            ForEach(groups) { group in
                                projectRow(group, total: total)
                                if expanded.contains(group.id) {
                                    ForEach(group.sessions, id: \.session.id) { SessionRow(session: $0.session, time: $0.time) }
                                }
                            }
                        }
                    }
                }
                .frame(height: Self.listHeight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func placeholder(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: Self.listHeight)
    }

    private func summary(sessions: Int, groups: [Repo]) -> String {
        let kinds = AgentKind.allCases.compactMap { kind -> String? in
            let t = groups.reduce(0) { $0 + $1.time(of: kind) }
            return t >= 60 ? "\(kind.rawValue) \(Fmt.short(t))" : nil
        }
        return (["\(sessions) \(sessions == 1 ? "session" : "sessions")"] + kinds).joined(separator: " · ")
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
    }

    private func projectRow(_ group: Repo, total: TimeInterval) -> some View {
        let open = expanded.contains(group.id)
        return HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(open ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.id).lineLimit(1)
                // Share of the period's agent time, split by agent.
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(AgentKind.allCases, id: \.self) { kind in
                            let t = group.time(of: kind)
                            if t > 0 {
                                Capsule().fill(kind.color)
                                    .frame(width: max(3, geo.size.width * t / max(total, 1)))
                            }
                        }
                    }
                }
                .frame(height: 3)
            }
            Spacer()
            Text(Fmt.short(group.time))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
        }
        .help("\(group.sessions.count) \(group.sessions.count == 1 ? "session" : "sessions")")
    }
}

private struct KindBadge: View {
    let kind: AgentKind

    var body: some View {
        Text(kind.rawValue)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(kind.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(kind.color.opacity(0.15)))
    }
}

private struct WorkingRow: View {
    let session: AgentSession
    let now: Date

    var body: some View {
        let since = session.current?.start ?? now
        HStack(spacing: 8) {
            Circle().fill(session.kind.color).frame(width: 7, height: 7)
                .opacity(Int(now.timeIntervalSince1970) % 2 == 0 ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1)
                HStack(spacing: 4) {
                    KindBadge(kind: session.kind)
                    Text([session.project, session.branch].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.clock(now.timeIntervalSince(since)))
                .font(.callout)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 8).fill(session.kind.color.opacity(0.10)))
        .help(session.cwd)
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let time: TimeInterval

    var body: some View {
        HStack(spacing: 6) {
            KindBadge(kind: session.kind)
            Text(session.title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(.primary.opacity(0.85))
            Spacer()
            Text(Fmt.short(time))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 24)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .help([session.title, session.branch.map { "Branch \($0)" }, session.cwd,
               "Last active \(session.lastActive.formatted(date: .abbreviated, time: .shortened))"]
            .compactMap { $0 }.joined(separator: "\n"))
    }
}
