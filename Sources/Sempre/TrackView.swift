import SwiftUI
import SempreCore

struct TrackView: View {
    @EnvironmentObject var store: Store
    @State private var newName = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            NowCard()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            HStack {
                Text("Projects")
                Spacer()
                Text("Today \(Fmt.short(store.total(in: store.today)))")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            Scrollable(when: store.projects.count > 8, height: 320) {
                VStack(spacing: 2) {
                    ForEach(store.projects) { ProjectRow(project: $0) }
                }
                .padding(.horizontal, 6)
            }

            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
                TextField("New project", text: $newName)
                    .textFieldStyle(.plain)
                    .focused($addFocused)
                    .onSubmit {
                        if let p = store.addProject(newName) {
                            newName = ""
                            if store.running == nil { store.start(p) }
                        }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            .padding(12)
        }
    }
}

struct NowCard: View {
    @EnvironmentObject var store: Store
    @State private var adjusting = false
    @State private var newStart = Date()

    var body: some View {
        let entry = store.running
        let project = entry.flatMap { store.project($0.projectID) }
        let sub = store.subproject(entry?.subprojectID)
        let color = project.map(\.swatch) ?? .secondary

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(project?.name ?? "Not tracking")
                            .foregroundStyle(project == nil ? .secondary : .primary)
                        if let sub {
                            Text("› \(sub.name)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.headline)
                    .lineLimit(1)
                    Text(entry.map { Fmt.clock($0.worked(now: store.now)) } ?? "Pick a project to start")
                        .font(entry == nil ? .callout : .system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(entry == nil ? .tertiary : .primary)
                    if let entry {
                        Button {
                            newStart = entry.start
                            adjusting.toggle()
                        } label: {
                            Text("since \(entry.start.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .underline(adjusting)
                        }
                        .buttonStyle(.plain)
                        .help("Change start time")
                    }
                }
                Spacer()
                if entry != nil {
                    Button { adjusting = false; store.stop() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(color))
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }
            }
            if adjusting, let entry {
                HStack {
                    Text("Started").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $newStart, in: ...Date()).labelsHidden()
                    Spacer()
                    Button("Set") {
                        store.updateEntry(entry.id, start: newStart, end: nil, subprojectID: entry.subprojectID)
                        adjusting = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(color)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(entry == nil ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(color.opacity(0.14)))
        )
        .onChange(of: entry?.id) { adjusting = false }
    }
}

struct ProjectRow: View {
    @EnvironmentObject var store: Store
    let project: Project
    @State private var hovering = false
    @State private var editing = false
    @State private var editName = ""
    @State private var confirmDelete = false
    @State private var expanded = false
    @State private var addingSub = false
    @State private var subName = ""

    var body: some View {
        let isRunning = store.isRunning(project.id)
        let color = project.swatch
        let subs = store.subprojects(of: project.id)

        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 9, height: 9)
                if editing {
                    TextField("Name", text: $editName)
                        .textFieldStyle(.plain)
                        .onSubmit { store.rename(project.id, to: editName); editing = false }
                        .onExitCommand { editing = false }
                } else {
                    Text(project.name).lineLimit(1)
                }
                if !subs.isEmpty {
                    Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide subprojects" : "Show \(subs.count) subprojects")
                }
                Spacer()
                if confirmDelete {
                    Button("Delete") { store.delete(project.id) }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                    Button("Cancel") { confirmDelete = false }
                        .controlSize(.small)
                } else {
                    Text(Fmt.short(store.total(for: project.id, in: store.today)))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(isRunning || hovering ? color : Color.secondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isRunning ? color.opacity(0.12) : (hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                guard !editing && !confirmDelete else { return }
                // A running subproject of this project stops; otherwise track the project itself.
                if isRunning { store.stop() } else { store.start(project) }
            }
            .contextMenu {
                Button("Add Subproject") { expanded = true; addingSub = true }
                Button("Rename") { editName = project.name; editing = true }
                Menu("Color") {
                    ForEach(Palette.colors.indices, id: \.self) { i in
                        Button { store.setColor(project.id, i) } label: {
                            Label {
                                Text(colorName(i))
                            } icon: {
                                Palette.menuSwatch(i, checked: project.rgb == nil && project.color % Palette.colors.count == i)
                            }
                        }
                    }
                }
                Divider()
                Button("Archive") { store.archive(project.id) }
                Button("Delete…", role: .destructive) { confirmDelete = true }
            }

            if expanded || addingSub {
                ForEach(subs) { SubprojectRow(project: project, sub: $0) }
                if addingSub {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.caption).foregroundStyle(.secondary)
                        TextField("Subproject name", text: $subName)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                store.addSubproject(subName, to: project.id)
                                subName = ""
                                addingSub = false
                            }
                            .onExitCommand { addingSub = false; subName = "" }
                    }
                    .padding(.leading, 29)
                    .padding(.trailing, 10)
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private func colorName(_ i: Int) -> String {
        ["Indigo", "Teal", "Orange", "Rose", "Violet", "Green", "Amber", "Sky"][i]
    }
}

struct SubprojectRow: View {
    @EnvironmentObject var store: Store
    let project: Project
    let sub: Subproject
    @State private var hovering = false

    var body: some View {
        let isRunning = store.isRunning(project.id, sub.id)
        let color = project.swatch

        HStack(spacing: 10) {
            Text(sub.name).font(.callout).lineLimit(1)
            Spacer()
            Text(Fmt.short(store.total(project: project.id, subproject: sub.id, in: store.today)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: isRunning ? "stop.circle.fill" : "play.circle")
                .font(.system(size: 15))
                .foregroundStyle(isRunning || hovering ? color : Color.secondary.opacity(0.5))
        }
        .padding(.leading, 29)
        .padding(.trailing, 11)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isRunning ? color.opacity(0.12) : (hovering ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.toggle(project, sub) }
        .contextMenu {
            Button("Archive Subproject") { store.archiveSubproject(sub.id) }
        }
    }
}

/// Plain stack for short lists; scrolls once the content would get too tall.
struct Scrollable<Content: View>: View {
    let when: Bool
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if when {
            ScrollView { content }.frame(height: height)
        } else {
            content
        }
    }
}

/// Small pill-style segmented switch.
struct Segmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Text(label(o))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selection == o ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selection == o ? Color(nsColor: .controlBackgroundColor) : .clear)
                            .shadow(color: .black.opacity(selection == o ? 0.12 : 0), radius: 1, y: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = o }
            }
        }
        // Only the switch itself animates: animating the content it swaps, while the panel resizes, makes it jump.
        .animation(.easeOut(duration: 0.15), value: selection)
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
    }
}
