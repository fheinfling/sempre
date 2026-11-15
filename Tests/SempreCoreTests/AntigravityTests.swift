import Foundation
import SQLite3
import Testing
@testable import SempreCore

@Suite("Agent work from Antigravity CLI conversations")
struct AntigravityTests {
    let t0 = Date(timeIntervalSince1970: 1_793_440_000)

    // MARK: Fixtures: protobuf messages and conversation databases as agy writes them

    func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        return out + [UInt8(v)]
    }
    func field(_ n: Int, _ v: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(v) }
    func field(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    func field(_ n: Int, _ s: String) -> [UInt8] { field(n, Array(s.utf8)) }
    func time(_ n: Int, _ minutes: Double) -> [UInt8] {
        let t = t0.timeIntervalSince1970 + minutes * 60
        return field(n, field(1, UInt64(t)) + field(2, UInt64((t - t.rounded(.down)) * 1e9)))
    }

    struct Step { var type: Int, status: Int, metadata: [UInt8], payload: [UInt8] }

    func step(_ type: Int, _ status: Int = 3, at created: Double, done: Double? = nil, payload: [UInt8] = []) -> Step {
        Step(type: type, status: status, metadata: time(1, created) + (done.map { time(8, $0) } ?? []), payload: payload)
    }
    func prompt(_ minutes: Double, _ text: String) -> Step { step(14, at: minutes, payload: field(19, field(2, text))) }
    func response(_ minutes: Double, done: Double? = nil, status: Int = 3, tools: Bool) -> Step {
        step(15, status, at: minutes, done: done, payload: field(20, field(1, "…") + (tools ? field(7, field(1, "call")) : [])))
    }
    func tool(_ minutes: Double, done: Double?, status: Int = 3) -> Step { step(132, status, at: minutes, done: done) }

    func workspace(root: String, folder: String = "file:///w/repo-wt/fix") -> [UInt8] {
        field(1, field(1, folder) + field(3, field(1, "me/repo") + field(2, "https://github.com/me/repo.git")) + field(4, "fix"))
            + field(6, root)
    }

    func exec(_ db: OpaquePointer?, _ sql: String, _ blobs: [[UInt8]] = [], ints: [Int] = []) {
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        for (i, v) in ints.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), Int64(v)) }
        for (i, b) in blobs.enumerated() {
            sqlite3_bind_blob(stmt, Int32(ints.count + i + 1), b, Int32(b.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)
    }

    /// A conversation database with agy's tables (the columns read here).
    @discardableResult
    func conversation(_ url: URL, meta: [UInt8]?, _ steps: [Step]) -> URL {
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        exec(db, "CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer, status integer, metadata blob, step_payload blob)")
        exec(db, "CREATE TABLE trajectory_metadata_blob (id text PRIMARY KEY, data blob)")
        if let meta { exec(db, "INSERT INTO trajectory_metadata_blob VALUES ('main', ?)", [meta]) }
        for (i, s) in steps.enumerated() {
            exec(db, "INSERT INTO steps VALUES (?, ?, ?, ?, ?)", [s.metadata, s.payload], ints: [i, s.type, s.status])
        }
        sqlite3_close(db)
        return url
    }

    func read(_ steps: [Step], meta: [UInt8]? = nil) -> AgentLog {
        let url = tempDir().appendingPathComponent("conv.db")
        return AgentLog.antigravity(at: conversation(url, meta: meta, steps))!
    }

    func minutes(_ spans: [DateInterval]) -> [Double] { spans.map { ($0.duration / 60 * 1000).rounded() / 1000 } }
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    // MARK: Turns

    @Test func aTurnRunsFromPromptToTheResponseWithoutToolCalls() {
        let log = read([
            prompt(0, "Fix the\n\n build"),
            response(0.1, done: 1, tools: true),
            tool(1, done: 4),
            response(4, done: 5, tools: false),
            // The human takes 20 minutes to reply: not agent time.
            prompt(25, "Thanks, now the tests"),
            response(25.5, done: 27, tools: false),
        ], meta: workspace(root: "conv"))
        #expect(minutes(log.spans(now: at(60))) == [5, 2])
        #expect(!log.isWorking(now: at(28)))
        #expect(log.prompt == "Fix the build")
        #expect(log.cwd == "/w/repo-wt/fix")
        #expect(log.repository == "repo")
        #expect(log.branch == "fix")
        #expect(log.sessionID == "conv")
        #expect(!log.isSubagent)
    }

    @Test func aResponseStillGeneratingKeepsTheTurnOpen() {
        // Its tool calls only show up once it's done, so for now it looks like a last response.
        let log = read([prompt(0, "Go"), tool(1, done: 2), response(3, status: 8, tools: false)])
        #expect(log.isWorking(now: at(4)))
        #expect(minutes(log.spans(now: at(4))) == [4])
    }

    @Test func cancellingEndsTheTurn() {
        let log = read([prompt(0, "Refactor everything"), response(1, done: 1.5, tools: true), tool(1.5, done: 3, status: 6)])
        #expect(!log.isWorking(now: at(4)))
        #expect(minutes(log.spans(now: at(4))) == [3])
    }

    @Test func aNewPromptEndsAnUnfinishedTurnAtItsLastActivity() {
        let log = read([prompt(0, "Go"), tool(1, done: 2, status: 7), prompt(5, "Try again")])
        #expect(minutes(log.spans(now: at(6))) == [2, 1])
        #expect(log.isWorking(now: at(6)))
    }

    @Test func aSubagentBelongsToItsRootConversation() {
        let url = tempDir().appendingPathComponent("child.db")
        let log = AgentLog.antigravity(at: conversation(url, meta: workspace(root: "parent"), [step(101, at: 0, done: 1)]))!
        #expect(log.sessionID == "parent")
        #expect(log.isSubagent)
    }

    @Test func somethingElseThanAConversationIsNotRead() throws {
        let url = tempDir().appendingPathComponent("other.db")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        exec(db, "CREATE TABLE t (x)")
        sqlite3_close(db)
        #expect(AgentLog.antigravity(at: url) == nil)
        try Data("not a database".utf8).write(to: url)
        #expect(AgentLog.antigravity(at: url) == nil)
    }

    // MARK: Scanner

    @Test func scannerMergesSubagentsAndTitlesSessions() throws {
        let home = tempDir()
        let root = home.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        conversation(root.appendingPathComponent("main.db"), meta: workspace(root: "main"),
                     [prompt(0, "Plan it"), response(0.5, done: 1, tools: true), tool(1, done: 2), response(2, done: 2.5, tools: false)])
        // A subagent working on after the main turn ended, overlapping it by a minute.
        conversation(root.appendingPathComponent("sub.db"), meta: workspace(root: "main"),
                     [step(101, at: 1.5), response(2, done: 6, tools: false)])
        var db: OpaquePointer?
        sqlite3_open(home.appendingPathComponent("conversation_summaries.db").path, &db)
        exec(db, "CREATE TABLE conversation_summaries (conversation_id text PRIMARY KEY, title text NOT NULL DEFAULT '')")
        exec(db, "INSERT INTO conversation_summaries VALUES ('main', 'Planning   the release'), ('sub', '')")
        sqlite3_close(db)

        let scanner = AgentScanner(roots: [.init(kind: .antigravity, url: root)])
        var sessions = scanner.scan(since: .distantPast, now: at(60))
        #expect(sessions.count == 1)
        #expect(sessions[0].id == "antigravity:main")
        #expect(sessions[0].kind == .antigravity)
        #expect(sessions[0].title == "Planning the release")
        #expect(sessions[0].project == "repo")
        #expect(sessions[0].branch == "fix")
        #expect(minutes(sessions[0].spans) == [6])

        // A changed conversation is read again: here the prompt was answered by a new turn.
        let main = root.appendingPathComponent("main.db")
        try FileManager.default.removeItem(at: main)
        conversation(main, meta: workspace(root: "main"), [prompt(0, "Plan it"), response(2, done: 2.5, tools: false),
                                                          prompt(20, "More"), response(21, done: 22, tools: false)])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: main.path)
        sessions = scanner.scan(since: .distantPast, now: at(60))
        #expect(minutes(sessions[0].spans) == [6, 2])
    }

    // MARK: Protobuf

    @Test func protoReadsNestedFieldsAndSkipsTheRest() {
        let m = Proto(field(3, 7) + [0x0D, 1, 2, 3, 4] + field(1, field(2, "inner") + field(2, "second")) + field(9, "x"))
        #expect(m.varint(3) == 7)
        #expect(m[1, 2]?.string == "inner")
        #expect(m[9]?.string == "x")
        #expect(m[1, 5] == nil)
        #expect(m[4] == nil)
    }

    @Test func protoStopsAtMalformedInput() {
        // A length running past the end, a truncated varint, a group (unsupported): nothing found, nothing read out of bounds.
        #expect(Proto([0x0A, 0x05, 0x01])[1] == nil)
        #expect(Proto([0x08, 0xFF])[1] == nil)
        #expect(Proto([0x0B, 0x0A, 0x01, 0x41])[1] == nil)
        #expect(Proto([])[1] == nil)
    }

    @Test func protoTimestamps() {
        let m = Proto(time(1, 1.5))
        #expect(abs(m[1]!.date!.timeIntervalSince(at(1.5))) < 0.001)
    }

    // MARK: Archive

    @Test func archiveSkipsSessionsOfAgentsItDoesntKnow() throws {
        let folder = tempDir()
        let json = """
            {"machine":"Other Mac","sessions":[
              {"id":"x:1","kind":"SomeFutureAgent","cwd":"/w","project":"w","title":"t","spans":[]},
              {"id":"antigravity:2","kind":"Antigravity","cwd":"/w","project":"w","title":"t",
               "spans":[{"start":"2026-10-31T10:00:00Z","duration":600}]}]}
            """
        try Data(json.utf8).write(to: folder.appendingPathComponent("mac-b.json"))
        let all = AgentArchive(folder: folder, machineID: "mac-a").update(with: [], horizon: .distantPast, now: t0)
        #expect(all.map(\.id) == ["antigravity:2"])
    }
}
