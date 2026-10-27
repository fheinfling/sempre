import Foundation
import Combine

/// Owns the library, saves every change to one JSON file and picks up changes made on other Macs.
@MainActor
public final class Store: ObservableObject {
    @Published public private(set) var library = Library()
    @Published public private(set) var now = Date()
    @Published public var lastError: String?

    public let fileURL: URL
    public let usesICloud: Bool
    private var lastModified: Date?
    private var timer: Timer?
    private var tickCount = 0

    /// The user's data file: iCloud Drive when available, otherwise Application Support.
    public convenience init() {
        let fm = FileManager.default
        let icloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) {
            self.init(fileURL: Store.dataFile(in: icloud), usesICloud: true)
        } else {
            self.init(fileURL: Store.dataFile(in: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]))
        }
    }

    public init(fileURL: URL, usesICloud: Bool = false) {
        self.fileURL = fileURL
        self.usesICloud = usesICloud
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        reloadIfChanged(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// `<root>/Sempre/sempre.json`. The app used to be called Tempo, so `<root>/Tempo/tempo.json` moves there once.
    public nonisolated static func dataFile(in root: URL) -> URL {
        let fm = FileManager.default
        let file = root.appendingPathComponent("Sempre/sempre.json")
        let legacy = root.appendingPathComponent("Tempo/tempo.json")
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: file)
            try? fm.removeItem(at: legacy.deletingLastPathComponent())
        }
        return file
    }

    // MARK: Derived

    /// Active projects, most recently used first.
    public var projects: [Project] {
        var lastUsed: [UUID: Date] = [:]
        for e in library.entries { lastUsed[e.projectID] = max(lastUsed[e.projectID] ?? .distantPast, e.start) }
        return library.projects.filter { !$0.archived }
            .sorted { (lastUsed[$0.id] ?? .distantFuture) > (lastUsed[$1.id] ?? .distantFuture) }
    }
    /// Every project, active first, then archived; alphabetical within each group.
    public var allProjects: [Project] {
        library.projects.sorted { ($0.archived ? 1 : 0, $0.name.lowercased()) < ($1.archived ? 1 : 0, $1.name.lowercased()) }
    }

    public func subprojects(of projectID: UUID) -> [Subproject] {
        library.subprojects.filter { $0.projectID == projectID && !$0.archived }
    }

    public var running: Entry? { library.entries.last { $0.end == nil } }
    public func project(_ id: UUID) -> Project? { library.projects.first { $0.id == id } }
    public func subproject(_ id: UUID?) -> Subproject? { id.flatMap { id in library.subprojects.first { $0.id == id } } }

    public func isRunning(_ projectID: UUID, _ subprojectID: UUID? = nil) -> Bool {
        guard let r = running, r.projectID == projectID else { return false }
        return subprojectID == nil || r.subprojectID == subprojectID
    }

    public func total(project projectID: UUID, subproject subID: UUID, in interval: DateInterval) -> TimeInterval {
        library.entries.reduce(0) { sum, e in
            e.projectID == projectID && e.subprojectID == subID ? sum + e.duration(in: interval, now: now) : sum
        }
    }

    /// Entries of one project overlapping the interval, newest first.
    public func entries(of projectID: UUID, in interval: DateInterval) -> [Entry] {
        library.entries
            .filter { $0.projectID == projectID && $0.span(in: interval, now: now) > 0 }
            .sorted { $0.start > $1.start }
    }

    /// First tracked moment, used for the "All" stats range.
    public var firstEntryStart: Date { library.entries.map(\.start).min() ?? now }

    public func total(for projectID: UUID? = nil, in interval: DateInterval) -> TimeInterval {
        library.entries.reduce(0) { sum, e in
            guard projectID == nil || e.projectID == projectID else { return sum }
            return sum + e.duration(in: interval, now: now)
        }
    }

    public func breakdown(in interval: DateInterval) -> [(project: Project, time: TimeInterval)] {
        var map: [UUID: TimeInterval] = [:]
        for e in library.entries {
            let d = e.duration(in: interval, now: now)
            if d > 0 { map[e.projectID, default: 0] += d }
        }
        return map.compactMap { id, t in project(id).map { ($0, t) } }.sorted { $0.time > $1.time }
    }

    public var today: DateInterval { Calendar.current.dateInterval(of: .day, for: now)! }

    // MARK: Actions

    public func toggle(_ project: Project, _ sub: Subproject? = nil) {
        if let r = running, r.projectID == project.id, r.subprojectID == sub?.id { stop() } else { start(project, sub) }
    }

    public func start(_ project: Project, _ sub: Subproject? = nil) {
        let t = Date()
        closeRunning(at: t)
        // Restarting the same thing within a minute of stopping it continues that entry.
        if let i = library.entries.indices.max(by: { (library.entries[$0].end ?? .distantPast) < (library.entries[$1].end ?? .distantPast) }),
           let end = library.entries[i].end, t.timeIntervalSince(end) < 60,
           library.entries[i].projectID == project.id, library.entries[i].subprojectID == sub?.id {
            library.entries[i].end = nil
            now = t
            save()
            return
        }
        library.entries.append(Entry(projectID: project.id, subprojectID: sub?.id, start: t))
        now = t
        save()
    }

    public func stop() {
        closeRunning(at: Date())
        save()
    }

    /// Closes the running entry; one shorter than 10 s was a mis-click and is dropped.
    private func closeRunning(at t: Date) {
        for i in library.entries.indices where library.entries[i].end == nil {
            library.entries[i].end = t
        }
        library.entries.removeAll { e in e.end.map { $0.timeIntervalSince(e.start) < 10 && $0 == t } ?? false }
    }

    @discardableResult
    public func addProject(_ name: String) -> Project? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let p = Project(name: name, color: library.projects.count)
        library.projects.append(p)
        save()
        return p
    }

    public func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = library.projects.firstIndex(where: { $0.id == id }) else { return }
        library.projects[i].name = name
        save()
    }

    public func setColor(_ id: UUID, _ color: Int) {
        guard let i = library.projects.firstIndex(where: { $0.id == id }) else { return }
        library.projects[i].color = color
        library.projects[i].rgb = nil
        save()
    }

    public func archive(_ id: UUID) {
        guard let i = library.projects.firstIndex(where: { $0.id == id }) else { return }
        if running?.projectID == id { closeRunning(at: Date()) }
        library.projects[i].archived = true
        save()
    }

    public func delete(_ id: UUID) {
        library.projects.removeAll { $0.id == id }
        library.subprojects.removeAll { $0.projectID == id }
        library.entries.removeAll { $0.projectID == id }
        save()
    }

    @discardableResult
    public func addSubproject(_ name: String, to projectID: UUID) -> Subproject? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let s = Subproject(projectID: projectID, name: name)
        library.subprojects.append(s)
        save()
        return s
    }

    public func archiveSubproject(_ id: UUID) {
        guard let i = library.subprojects.firstIndex(where: { $0.id == id }) else { return }
        if running?.subprojectID == id { closeRunning(at: Date()) }
        library.subprojects[i].archived = true
        save()
    }

    // MARK: Entries

    public func updateEntry(_ id: UUID, start: Date, end: Date?, subprojectID: UUID?, breaks: [Break]? = nil) {
        guard let i = library.entries.firstIndex(where: { $0.id == id }) else { return }
        library.entries[i].start = start
        library.entries[i].end = end
        library.entries[i].subprojectID = subprojectID
        if let breaks { library.entries[i].breaks = breaks.isEmpty ? nil : breaks }
        library.entries.sort { $0.start < $1.start }
        save()
    }

    public func addEntry(projectID: UUID, subprojectID: UUID?, start: Date, end: Date, breaks: [Break] = []) {
        library.entries.append(Entry(projectID: projectID, subprojectID: subprojectID, start: start, end: end,
                                     breaks: breaks.isEmpty ? nil : breaks))
        library.entries.sort { $0.start < $1.start }
        save()
    }

    public func deleteEntries(_ ids: Set<UUID>) {
        library.entries.removeAll { ids.contains($0.id) }
        save()
    }

    public func deleteEntry(_ id: UUID) {
        library.entries.removeAll { $0.id == id }
        save()
    }

    /// Adds imported entries, matching projects and subprojects by name (ignoring case) and creating missing ones.
    /// Entries already there (same project, start and end) are skipped, so importing a file twice adds nothing.
    @discardableResult
    public func importEntries(_ rows: [CSVImport.Row]) -> (projects: Int, entries: Int) {
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        func entryKey(_ projectID: UUID, _ start: Date, _ end: Date) -> String {
            "\(projectID)/\(Int(start.timeIntervalSinceReferenceDate))/\(Int(end.timeIntervalSinceReferenceDate))"
        }
        var projectIDs = Dictionary(library.projects.map { (key($0.name), $0.id) }) { first, _ in first }
        var subprojectIDs = Dictionary(library.subprojects.map { ("\($0.projectID)/\(key($0.name))", $0.id) }) { first, _ in first }
        var known = Set(library.entries.compactMap { e in e.end.map { entryKey(e.projectID, e.start, $0) } })
        var newProjects = 0, newEntries = 0
        for row in rows {
            let name = row.project.trimmingCharacters(in: .whitespaces)
            let projectID: UUID
            if let id = projectIDs[key(name)] {
                projectID = id
            } else {
                let p = Project(name: name, color: library.projects.count)
                library.projects.append(p)
                projectIDs[key(name)] = p.id
                projectID = p.id
                newProjects += 1
            }
            guard known.insert(entryKey(projectID, row.start, row.end)).inserted else { continue }
            var subprojectID: UUID?
            if let task = row.task?.trimmingCharacters(in: .whitespaces), !task.isEmpty {
                let k = "\(projectID)/\(key(task))"
                if let id = subprojectIDs[k] {
                    subprojectID = id
                } else {
                    let s = Subproject(projectID: projectID, name: task)
                    library.subprojects.append(s)
                    subprojectIDs[k] = s.id
                    subprojectID = s.id
                }
            }
            library.entries.append(Entry(projectID: projectID, subprojectID: subprojectID, start: row.start, end: row.end))
            newEntries += 1
        }
        library.entries.sort { $0.start < $1.start }
        save()
        return (newProjects, newEntries)
    }

    // MARK: Persistence

    private func tick() {
        tickCount += 1
        if running != nil || tickCount % 30 == 0 { now = Date() }
        if tickCount % 5 == 0 { reloadIfChanged() }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    public func reloadIfChanged(force: Bool = false) {
        guard let mod = modificationDate() else {
            if usesICloud { try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL) }
            return
        }
        guard force || mod != lastModified else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            library = try dec.decode(Library.self, from: data)
            lastModified = mod
            now = Date()
        } catch {
            lastError = "Could not read data: \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(library).write(to: fileURL, options: .atomic)
            lastModified = modificationDate()
            lastError = nil
        } catch {
            lastError = "Could not save: \(error.localizedDescription)"
        }
    }
}
