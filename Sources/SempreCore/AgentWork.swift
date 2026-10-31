import Foundation
import Combine
import CryptoKit
import IOKit

/// Coding agents whose work Sempre can follow, from the session transcripts they write anyway:
/// Claude Code (`~/.claude/projects/<folder>/<session>.jsonl`) and Codex (`~/.codex/sessions/YYYY/MM/DD/*.jsonl`).
public enum AgentKind: String, CaseIterable, Codable, Sendable {
    case claude = "Claude"
    case codex = "Codex"
}

/// One agent session: where it ran and when it was working.
public struct AgentSession: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let kind: AgentKind
    public let cwd: String
    /// The repository (or folder) it worked in; worktrees count as their main repository.
    public let project: String
    public let branch: String?
    public let title: String
    /// Working time, merged; a span still running ends at the scan's `now`.
    public internal(set) var spans: [DateInterval]
    /// Only known for this Mac's sessions, from the latest scan; never saved.
    public internal(set) var working = false

    private enum CodingKeys: String, CodingKey { case id, kind, cwd, project, branch, title, spans }

    public init(id: String, kind: AgentKind, cwd: String, project: String, branch: String? = nil, title: String,
                spans: [DateInterval], working: Bool) {
        self.id = id
        self.kind = kind
        self.cwd = cwd
        self.project = project
        self.branch = branch
        self.title = title
        self.spans = spans
        self.working = working
    }

    /// Working time inside the interval. With `now`, a span still running continues past the last scan
    /// (but never by more than the idle gap, should scanning stop).
    public func time(in interval: DateInterval, now: Date? = nil) -> TimeInterval {
        var spans = spans
        if working, let now, let last = spans.last, now > last.end {
            spans[spans.count - 1] = DateInterval(start: last.start, end: min(now, last.end.addingTimeInterval(AgentLog.idleGap)))
        }
        return spans.reduce(0) { sum, s in
            sum + max(0, min(s.end, interval.end).timeIntervalSince(max(s.start, interval.start)))
        }
    }

    /// The span it's working in right now.
    public var current: DateInterval? { working ? spans.last : nil }
    public var lastActive: Date { spans.last?.end ?? .distantPast }
}

/// Working spans of one transcript file, read incrementally as the agent appends to it.
/// A span runs from the first activity until the agent ends its turn, or until it has been silent for `idleGap`
/// (a long tool run counts; a question left waiting for hours doesn't).
public struct AgentLog {
    public static let idleGap: TimeInterval = 10 * 60

    public let kind: AgentKind
    public var sessionID: String
    public var cwd: String?
    /// Title the agent gave the session (Claude's own title).
    public var title: String?
    /// The first thing it was asked, as a fallback title.
    public var prompt: String?
    /// Repository name the agent reported (Codex), which outlives a deleted worktree.
    public var repository: String?
    /// The git branch it was on, as of its latest activity.
    public var branch: String?
    /// A subagent's transcript, counted towards the session that started it.
    public var isSubagent = false
    public private(set) var spans: [DateInterval] = []
    private var open: (start: Date, last: Date)?
    /// Bytes read so far, always just past a newline.
    var offset = 0

    public init(kind: AgentKind, sessionID: String) {
        self.kind = kind
        self.sessionID = sessionID
    }

    public mutating func add(_ t: Date, endsTurn: Bool = false) {
        if let o = open, t.timeIntervalSince(o.last) <= Self.idleGap {
            open = (o.start, max(o.last, t))
        } else {
            close()
            open = (t, t)
        }
        if endsTurn { close() }
    }

    private mutating func close() {
        if let o = open, o.last > o.start { spans.append(DateInterval(start: o.start, end: o.last)) }
        open = nil
    }

    public func isWorking(now: Date) -> Bool {
        open.map { now.timeIntervalSince($0.last) < Self.idleGap } ?? false
    }

    /// Closed spans plus the open one, which runs until `now` while the agent is still working.
    public func spans(now: Date) -> [DateInterval] {
        guard let o = open else { return spans }
        let end = isWorking(now: now) ? max(now, o.last) : o.last
        return end > o.start ? spans + [DateInterval(start: o.start, end: end)] : spans
    }

    /// Reads the complete lines in `data` from `offset` on and moves `offset` past them.
    public mutating func read(_ data: Data) {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var i = offset
            while i < buf.count, let nl = memchr(base + i, 0x0A, buf.count - i) {
                let end = base.distance(to: nl)
                if end > i { line(JSONSkim(buf), i..<end) }
                i = end + 1
            }
            offset = i
        }
    }

    private mutating func line(_ j: JSONSkim, _ range: Range<Int>) {
        switch kind {
        case .claude: claudeLine(j, range)
        case .codex: codexLine(j, range)
        }
    }

    private static let claudeKeys = JSONSkim.keys("type", "timestamp", "message", "isMeta", "aiTitle", "cwd", "gitBranch")
    private static let messageKeys = JSONSkim.keys("stop_reason", "content")

    private mutating func claudeLine(_ j: JSONSkim, _ range: Range<Int>) {
        let f = j.fields(range, Self.claudeKeys)
        guard let type = f[0].flatMap(j.string) else { return }
        if type == "ai-title" {
            title = f[4].flatMap(j.string) ?? title
            return
        }
        guard type == "user" || type == "assistant", let t = f[1].flatMap(j.date), f[3].map(j.isTrue) != true else { return }
        if cwd == nil { cwd = f[5].flatMap(j.string) }
        if let b = f[6].flatMap(j.string), !b.isEmpty, b != "HEAD" { branch = b }
        let message = f[2].map { j.fields($0, Self.messageKeys) } ?? [nil, nil]
        if type == "assistant" {
            add(t, endsTurn: message[0].flatMap(j.string) == "end_turn")
            return
        }
        // A user line: a prompt, a tool result, or the app's own bookkeeping (slash commands, reminders).
        let texts = message[1].map(j.texts) ?? []
        if texts.contains(where: { $0.hasPrefix("[Request interrupted") }) { add(t, endsTurn: true); return }
        let typed = texts.filter { !$0.hasPrefix("<") }
        if !texts.isEmpty && typed.isEmpty { return }
        if prompt == nil { prompt = typed.lazy.compactMap(AgentLog.clean).first }
        add(t)
    }

    private static let codexKeys = JSONSkim.keys("timestamp", "type", "payload")
    private static let payloadKeys = JSONSkim.keys("type", "id", "cwd", "role", "content", "message", "parent_thread_id", "git")
    private static let gitKeys = JSONSkim.keys("repository_url", "branch")

    private mutating func codexLine(_ j: JSONSkim, _ range: Range<Int>) {
        let f = j.fields(range, Self.codexKeys)
        guard let t = f[0].flatMap(j.date), let type = f[1].flatMap(j.string) else { return }
        let p = f[2].map { j.fields($0, Self.payloadKeys) } ?? Array(repeating: nil, count: Self.payloadKeys.count)
        let ptype = p[0].flatMap(j.string)
        switch (type, ptype) {
        case ("session_meta", _):
            sessionID = p[1].flatMap(j.string) ?? sessionID
            cwd = p[2].flatMap(j.string) ?? cwd
            if let parent = p[6].flatMap(j.string) {
                sessionID = parent
                isSubagent = true
            }
            let git = p[7].map { j.fields($0, Self.gitKeys) } ?? [nil, nil]
            // "https://github.com/owner/name.git" → "name"
            if let url = git[0].flatMap(j.string), let name = url.split(separator: "/").last {
                repository = name.hasSuffix(".git") ? String(name.dropLast(4)) : String(name)
            }
            branch = git[1].flatMap(j.string) ?? branch
            return
        case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
            add(t, endsTurn: true)
            return
        case ("event_msg", "user_message"):
            if prompt == nil { prompt = p[5].flatMap(j.string).flatMap(AgentLog.prompt) }
        case ("response_item", "message") where p[3].flatMap(j.string) == "user":
            // Codex sends its instructions and environment as user messages too.
            if prompt == nil { prompt = p[4].flatMap(j.texts).flatMap { $0.lazy.compactMap(AgentLog.prompt).first } }
        default: break
        }
        add(t)
    }

    private static func prompt(_ text: String) -> String? {
        text.hasPrefix("<") || text.hasPrefix("# AGENTS.md") ? nil : clean(text)
    }

    /// One line, at most 80 characters.
    static func clean(_ text: String) -> String? {
        let one = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !one.isEmpty else { return nil }
        return one.count > 80 ? String(one.prefix(79)) + "…" : one
    }
}

/// Finds agent transcripts, reads what's new in them and sums them up per session.
/// Not thread-safe: use it from one queue at a time.
public final class AgentScanner: @unchecked Sendable {
    public struct Root: Hashable, Sendable {
        public let kind: AgentKind
        public let url: URL
        public init(kind: AgentKind, url: URL) {
            self.kind = kind
            self.url = url
        }
    }

    public let roots: [Root]
    private var files: [String: (log: AgentLog, size: Int, modified: Date)] = [:]
    private var projects: [String: String] = [:]
    private var threadNames: [URL: (modified: Date, names: [String: String])] = [:]

    public init(roots: [Root] = AgentScanner.defaultRoots()) {
        self.roots = roots
    }

    /// `~/.claude/projects` and `~/.codex/sessions`, plus the folders `CLAUDE_CONFIG_DIR` and `CODEX_HOME` point to.
    public static func defaultRoots() -> [Root] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        var claude = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".config/claude")]
        var codex = [home.appendingPathComponent(".codex")]
        if let dir = env["CLAUDE_CONFIG_DIR"] { claude.append(URL(fileURLWithPath: dir)) }
        if let dir = env["CODEX_HOME"] { codex.append(URL(fileURLWithPath: dir)) }
        let all = claude.map { Root(kind: .claude, url: $0.appendingPathComponent("projects")) }
            + codex.map { Root(kind: .codex, url: $0.appendingPathComponent("sessions")) }
        // Several of these can be links to the same folder.
        var seen = Set<String>()
        return all.compactMap { r in
            let url = r.url.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: url.path), seen.insert(url.path).inserted else { return nil }
            return Root(kind: r.kind, url: url)
        }
    }

    /// Sessions with any activity in files changed since `since`, most recently active first.
    public func scan(since: Date, now: Date = Date()) -> [AgentSession] {
        var seen = Set<String>()
        for root in roots {
            for (url, size, modified) in transcripts(in: root.url) where modified >= since {
                seen.insert(url.path)
                if let known = files[url.path], known.size == size, known.modified == modified { continue }
                var log = files[url.path].flatMap { $0.size <= size ? $0.log : nil }
                    ?? Self.log(for: url, kind: root.kind)
                if let data = try? Data(contentsOf: url, options: .alwaysMapped) { log.read(data) }
                files[url.path] = (log, size, modified)
            }
        }
        files = files.filter { seen.contains($0.key) }
        return sessions(now: now)
    }

    private func sessions(now: Date) -> [AgentSession] {
        let groups = Dictionary(grouping: files.values.map { $0.log }) { "\($0.kind.rawValue.lowercased()):\($0.sessionID)" }
        return groups.compactMap { id, logs -> AgentSession? in
            // The session's own transcript first: its title and folder win over its subagents'.
            let logs = logs.sorted { !$0.isSubagent && $1.isSubagent }
            let spans = Self.merge(logs.flatMap { $0.spans(now: now) })
            guard !spans.isEmpty, let first = logs.first else { return nil }
            let cwd = logs.lazy.compactMap(\.cwd).first ?? ""
            let name = first.kind == .codex ? threadName(of: first.sessionID) : nil
            let title = name ?? logs.lazy.compactMap(\.title).first ?? logs.lazy.compactMap(\.prompt).first ?? "Untitled session"
            let project = logs.lazy.compactMap(\.repository).first ?? project(of: cwd)
            return AgentSession(id: id, kind: first.kind, cwd: cwd, project: project, branch: logs.lazy.compactMap(\.branch).first,
                                title: title, spans: spans,
                                working: logs.contains { $0.isWorking(now: now) })
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    /// Claude: `<folder>/<session>.jsonl`, with subagents in `<folder>/<session>/subagents/*.jsonl`.
    /// Codex: `YYYY/MM/DD/rollout-….jsonl`.
    private func transcripts(in root: URL) -> [(URL, Int, Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var result: [(URL, Int, Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let size = v.fileSize, let mod = v.contentModificationDate else { continue }
            result.append((url, size, mod))
        }
        return result
    }

    /// A new log named after its file; Codex names the session (and its parent) inside the file.
    static func log(for url: URL, kind: AgentKind) -> AgentLog {
        let parent = url.deletingLastPathComponent()
        if kind == .claude, parent.lastPathComponent == "subagents" {
            var log = AgentLog(kind: kind, sessionID: parent.deletingLastPathComponent().lastPathComponent)
            log.isSubagent = true
            return log
        }
        return AgentLog(kind: kind, sessionID: url.deletingPathExtension().lastPathComponent)
    }

    static func merge(_ spans: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, s.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, s.end))
            } else {
                result.append(s)
            }
        }
        return result
    }

    private func project(of cwd: String) -> String {
        if let p = projects[cwd] { return p }
        let p = Self.repository(of: URL(fileURLWithPath: cwd))
        projects[cwd] = p
        return p
    }

    /// The name of the git repository `dir` is in (the main one for a worktree), or else the folder's own name.
    static func repository(of dir: URL) -> String {
        let fm = FileManager.default
        var d = dir.standardizedFileURL
        while d.path != "/" {
            let git = d.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
                // A worktree's .git is a file: "gitdir: /path/to/repo/.git/worktrees/<name>".
                if !isDir.boolValue, let text = try? String(contentsOf: git, encoding: .utf8),
                   let r = text.range(of: "/.git/worktrees/") {
                    let repo = text[..<r.lowerBound].replacingOccurrences(of: "gitdir:", with: "").trimmingCharacters(in: .whitespaces)
                    return URL(fileURLWithPath: repo).lastPathComponent
                }
                return d.lastPathComponent
            }
            d = d.deletingLastPathComponent()
        }
        return dir.lastPathComponent.isEmpty ? "Unknown" : dir.lastPathComponent
    }

    /// Codex keeps the names of its threads in `<home>/session_index.jsonl`.
    private func threadName(of id: String) -> String? {
        for root in roots where root.kind == .codex {
            let index = root.url.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
            guard let mod = (try? index.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            if threadNames[index]?.modified != mod {
                var names: [String: String] = [:]
                for line in ((try? String(contentsOf: index, encoding: .utf8)) ?? "").split(separator: "\n") {
                    guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let id = o["id"] as? String, let name = o["thread_name"] as? String else { continue }
                    names[id] = AgentLog.clean(name)
                }
                threadNames[index] = (mod, names)
            }
            if let name = threadNames[index]?.names[id] { return name }
        }
        return nil
    }
}

/// Sempre's own record of agent sessions, so they outlive the agents' logs (Claude Code deletes its transcripts
/// after 30 days). Each Mac writes its sessions to `<folder>/<machine id>.json` and reads every Mac's file,
/// so Macs syncing through iCloud Drive never overwrite each other.
/// Not thread-safe: use it from one queue at a time.
public final class AgentArchive: @unchecked Sendable {
    struct File: Codable {
        var machine: String
        var sessions: [AgentSession]
    }

    public let folder: URL
    public let fileURL: URL
    /// True until this Mac has a record: the first scan then reads every transcript there is.
    public private(set) var isNew: Bool
    public private(set) var lastError: String?
    private var own: [String: AgentSession] = [:]
    private var others: [String: (modified: Date, sessions: [AgentSession])] = [:]
    private var dirty = false
    private var lastSave = Date.distantPast
    /// Saving waits this long after the last save; a crash loses nothing the transcripts don't still have.
    static let saveInterval: TimeInterval = 60

    public init(folder: URL, machineID: String) {
        self.folder = folder
        fileURL = folder.appendingPathComponent("\(machineID).json")
        isNew = !FileManager.default.fileExists(atPath: fileURL.path)
        if let file = Self.read(fileURL) { own = Dictionary(file.sessions.map { ($0.id, $0) }) { a, _ in a } }
    }

    /// Takes in a scan, which is complete for everything since `horizon`, and returns every Mac's sessions,
    /// this Mac's from the scan where it has them (so they're live).
    public func update(with scanned: [AgentSession], horizon: Date, now: Date = Date()) -> [AgentSession] {
        for s in scanned {
            let stored = own[s.id]
            var record = s
            record.working = false
            // Spans from before the horizon come from the record (their transcripts may be gone), the rest from the scan.
            // A span still running is saved once it's done.
            let done = s.working ? Array(s.spans.dropLast()) : s.spans
            record.spans = AgentScanner.merge((stored?.spans.filter { $0.end < horizon } ?? []) + done)
            if !record.spans.isEmpty, record != stored {
                own[s.id] = record
                dirty = true
            }
        }
        isNew = false
        if dirty, now.timeIntervalSince(lastSave) >= Self.saveInterval { save(now: now) }
        readOthers()

        var all: [String: AgentSession] = [:]
        for other in others.values { for s in other.sessions { all[s.id] = s } }
        for (id, s) in own { all[id] = s }
        for s in scanned {
            var live = s
            live.spans = AgentScanner.merge((own[s.id]?.spans ?? []) + s.spans)
            all[s.id] = live
        }
        return all.values.sorted { $0.lastActive > $1.lastActive }
    }

    public func save(now: Date = Date()) {
        let machine = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let file = File(machine: machine, sessions: own.values.sorted { ($0.spans.first?.start ?? .distantPast) < ($1.spans.first?.start ?? .distantPast) })
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(file).write(to: fileURL, options: .atomic)
            dirty = false
            lastSave = now
            lastError = nil
        } catch {
            lastError = "Could not save agent sessions: \(error.localizedDescription)"
        }
    }

    /// The other Macs' files, read again when they change. iCloud may only have placeholders for them at first.
    private func readOthers() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(".") && name.hasSuffix(".json.icloud") {
            try? fm.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(String(name.dropFirst().dropLast(7))))
        }
        var seen = Set<String>()
        for name in names where name.hasSuffix(".json") && name != fileURL.lastPathComponent {
            let url = folder.appendingPathComponent(name)
            guard let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            seen.insert(name)
            if others[name]?.modified == mod { continue }
            others[name] = (mod, Self.read(url)?.sessions ?? [])
        }
        others = others.filter { seen.contains($0.key) }
    }

    private static func read(_ url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(File.self, from: data)
    }
}

/// Follows agent work in the background while it's turned on (⋯ › Track Agent Work).
@MainActor
public final class AgentTracker: ObservableObject {
    public static let enabledKey = "trackAgents"

    /// Every recorded session, most recently active first.
    @Published public private(set) var sessions: [AgentSession] = []
    /// False until the first scan is done (which can read a month of transcripts, or all of them the first time).
    @Published public private(set) var loaded = false

    private let scanner: AgentScanner
    private let archive: AgentArchive?
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "sempre.agents", qos: .utility)
    private var busy = false
    private var timer: Timer?

    /// Keeps the record in `folder` (next to the data file); without one, sessions only last as long as the transcripts.
    public init(folder: URL? = nil, scanner: AgentScanner = AgentScanner(), defaults: UserDefaults = .standard) {
        self.scanner = scanner
        self.defaults = defaults
        archive = folder.map { AgentArchive(folder: $0, machineID: Self.machineID()) }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    public var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// Names this Mac's record: a hash of its hardware UUID, the same for every build and install of Sempre.
    static func machineID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? ProcessInfo.processInfo.hostName
        return SHA256.hash(data: Data(uuid.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads what's new in the transcripts, as far back as this week and this month.
    public func refresh() {
        guard enabled else {
            if loaded { sessions = []; loaded = false }
            return
        }
        guard !busy else { return }
        busy = true
        let cal = Calendar.current, now = Date()
        let scanner = scanner, archive = archive
        queue.async {
            let since = archive?.isNew == true ? .distantPast
                : min(cal.dateInterval(of: .month, for: now)!.start, cal.dateInterval(of: .weekOfYear, for: now)!.start)
            let scanned = scanner.scan(since: since, now: now)
            let found = archive?.update(with: scanned, horizon: since, now: now) ?? scanned
            DispatchQueue.main.async {
                self.busy = false
                guard self.enabled else { return }
                if found != self.sessions { self.sessions = found }
                self.loaded = true
            }
        }
    }
}

/// Reads the top level of a JSON object without building the rest: transcripts carry whole files and tool output,
/// and parsing every line in full takes tens of seconds for a month of them.
struct JSONSkim {
    let b: UnsafeRawBufferPointer

    init(_ b: UnsafeRawBufferPointer) { self.b = b }

    static func keys(_ names: String...) -> [[UInt8]] { names.map { Array($0.utf8) } }

    /// Byte ranges of the values of `keys` (in that order) in the object at `range`; nil where missing.
    func fields(_ range: Range<Int>, _ keys: [[UInt8]]) -> [Range<Int>?] {
        var result = [Range<Int>?](repeating: nil, count: keys.count)
        var i = ws(range.lowerBound, range.upperBound)
        guard i < range.upperBound, b[i] == UInt8(ascii: "{") else { return result }
        i += 1
        while true {
            i = ws(i, range.upperBound)
            guard i < range.upperBound, b[i] == UInt8(ascii: "\"") else { return result }
            let keyEnd = skip(i, range.upperBound)
            let key = (i + 1)..<(keyEnd - 1)
            i = ws(keyEnd, range.upperBound)
            guard i < range.upperBound, b[i] == UInt8(ascii: ":") else { return result }
            i = ws(i + 1, range.upperBound)
            let valueEnd = skip(i, range.upperBound)
            if let k = keys.firstIndex(where: { $0.count == key.count && b[key].elementsEqual($0) }) {
                result[k] = i..<valueEnd
            }
            i = ws(valueEnd, range.upperBound)
            guard i < range.upperBound, b[i] == UInt8(ascii: ",") else { return result }
            i += 1
        }
    }

    /// Byte ranges of the elements of the array at `range`.
    func elements(_ range: Range<Int>) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var i = ws(range.lowerBound, range.upperBound)
        guard i < range.upperBound, b[i] == UInt8(ascii: "[") else { return result }
        i += 1
        while true {
            i = ws(i, range.upperBound)
            guard i < range.upperBound, b[i] != UInt8(ascii: "]") else { return result }
            let end = skip(i, range.upperBound)
            result.append(i..<end)
            i = ws(end, range.upperBound)
            guard i < range.upperBound, b[i] == UInt8(ascii: ",") else { return result }
            i += 1
        }
    }

    func string(_ range: Range<Int>) -> String? {
        guard range.count >= 2, b[range.lowerBound] == UInt8(ascii: "\"") else { return nil }
        let inner = b[(range.lowerBound + 1)..<(range.upperBound - 1)]
        if !inner.contains(UInt8(ascii: "\\")) { return String(decoding: inner, as: UTF8.self) }
        return (try? JSONSerialization.jsonObject(with: Data(b[range]), options: .fragmentsAllowed)) as? String
    }

    func isTrue(_ range: Range<Int>) -> Bool { b[range].elementsEqual("true".utf8) }

    /// Text of a message's content: a plain string, or the text blocks of a list of content blocks.
    func texts(_ range: Range<Int>) -> [String] {
        if let s = string(range) { return [s] }
        return elements(range).compactMap { el in
            let f = fields(el, Self.textKeys)
            guard let type = f[0].flatMap(string), type == "text" || type == "input_text" else { return nil }
            return f[1].flatMap(string)
        }
    }

    private static let textKeys = keys("type", "text")

    /// `"2026-10-31T12:32:45.248Z"`, the form both agents write. Parsed by hand: a formatter is too slow for a month of lines.
    func date(_ range: Range<Int>) -> Date? {
        guard range.count >= 22, b[range.lowerBound] == UInt8(ascii: "\"") else { return nil }
        let s = range.lowerBound + 1
        func num(_ at: Int, _ len: Int) -> Int? {
            var n = 0
            for i in (s + at)..<(s + at + len) {
                let c = Int(b[i]) - 48
                guard (0...9).contains(c) else { return nil }
                n = n * 10 + c
            }
            return n
        }
        guard var y = num(0, 4), let m = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2),
              let sec = num(17, 2), (1...12).contains(m) else { return nil }
        var i = s + 19, frac = 0.0, scale = 0.1
        if b[i] == UInt8(ascii: ".") {
            i += 1
            while i < range.upperBound - 1, b[i] >= 48, b[i] <= 57 {
                frac += Double(b[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        guard b[i] == UInt8(ascii: "Z") else { return nil }
        // Days since 1970 from a civil date (Howard Hinnant's algorithm).
        y -= m <= 2 ? 1 : 0
        let era = y / 400, yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
        return Date(timeIntervalSince1970: Double(days * 86400 + h * 3600 + mi * 60 + sec) + frac)
    }

    private func ws(_ i: Int, _ end: Int) -> Int {
        var i = i
        while i < end, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        return i
    }

    /// Index just past the value starting at `i`.
    private func skip(_ i: Int, _ end: Int) -> Int {
        guard i < end else { return end }
        var i = i
        switch b[i] {
        case UInt8(ascii: "\""):
            i += 1
            while i < end {
                if b[i] == UInt8(ascii: "\\") { i += 2; continue }
                if b[i] == UInt8(ascii: "\"") { return i + 1 }
                i += 1
            }
            return end
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while i < end {
                switch b[i] {
                case UInt8(ascii: "\""): i = skip(i, end); continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            return end
        default:
            // A number, true, false or null.
            while i < end {
                switch b[i] {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D: return i
                default: i += 1
                }
            }
            return i
        }
    }
}
