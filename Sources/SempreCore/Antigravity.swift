import Foundation
import SQLite3

/// The Antigravity CLI (`agy`) keeps each conversation in an SQLite database, `conversations/<id>.db`, one row per step
/// (a prompt, a model response, a tool call…) with protobuf blobs for the step and its metadata.
extension AgentLog {
    /// The `CortexStep` types and statuses that matter here.
    private enum Step {
        static let userInput = 14, plannerResponse = 15
        static let done = 3, canceled = 6, interrupted = 12
    }

    /// Reads a whole conversation. Every step records when it was created and, once finished, when it completed;
    /// both are activity, as a transcript's lines are (a step's whole run isn't: a command can wait for approval).
    /// Steps overlap (tools run side by side), so their activity is taken in time order rather than step order.
    /// A prompt starts a turn; a finished response without tool calls ends it, and so does cancelling.
    /// Steps change in place while they run (a response only gets its tool calls once it's generated), so a changed
    /// conversation is read again in full; they're small next to a transcript. Nil if it can't be read right now.
    static func antigravity(at url: URL) -> AgentLog? {
        guard let db = SQLiteReader(url) else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        var log = AgentLog(kind: .antigravity, sessionID: id)

        // CortexTrajectoryMetadata: 1 workspaces, 6 the root conversation (a subagent's isn't its own), 7 workspace URIs.
        db.rows("SELECT data FROM trajectory_metadata_blob LIMIT 1") { row in
            let meta = Proto(row.blob(0))
            if let root = meta[6]?.string, !root.isEmpty, root != id {
                log.sessionID = root
                log.isSubagent = true
            }
            // CortexWorkspaceMetadata: 1 folder URI, 3 repository (1 "owner/name", 2 remote URL), 4 branch.
            let ws = meta[1]
            if let uri = ws?[1]?.string ?? meta[7]?.string, let folder = URL(string: uri), folder.isFileURL {
                log.cwd = folder.path
            }
            if let repo = ws?[3, 1]?.string ?? ws?[3, 2]?.string, let name = repo.split(separator: "/").last {
                log.repository = name.hasSuffix(".git") ? String(name.dropLast(4)) : String(name)
            }
            if let branch = ws?[4]?.string, !branch.isEmpty { log.branch = branch }
        }

        struct Activity { var at: Date, startsTurn = false, endsTurn = false }
        var activity: [Activity] = []
        // Payloads only where needed: a response's tool calls, and the prompt.
        let read = db.rows("""
            SELECT step_type, status, metadata, CASE WHEN step_type IN (14, 15) THEN step_payload END FROM steps ORDER BY idx
            """) { row in
            let type = row.int(0), status = row.int(1)
            // CortexStepMetadata: 1 created, 7 finished generating, 8 completed.
            let meta = Proto(row.blob(2))
            guard let created = meta[1]?.date else { return }
            let finished = meta[8]?.date ?? meta[7]?.date
            let payload = Proto(row.blob(3))
            var ends = status == Step.canceled || status == Step.interrupted
            if type == Step.userInput, log.prompt == nil {
                // CortexStepUserInput (payload 19): 2 the text as typed, 3 its items.
                log.prompt = (payload[19, 2]?.string ?? payload[19, 3, 1]?.string).flatMap(AgentLog.clean)
            }
            // CortexStepPlannerResponse (payload 20): 7 tool calls.
            if type == Step.plannerResponse, status == Step.done, payload[20, 7] == nil { ends = true }
            activity.append(Activity(at: created, startsTurn: type == Step.userInput, endsTurn: ends && finished == nil))
            if let finished { activity.append(Activity(at: finished, endsTurn: ends)) }
        }
        // A stable sort: activity at the same moment stays in step order.
        for a in activity.enumerated().sorted(by: { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }).map(\.element) {
            log.add(a.at, startsTurn: a.startsTurn, endsTurn: a.endsTurn)
        }
        return read ? log : nil
    }

    /// The titles Antigravity gave its conversations, from `conversation_summaries.db`.
    static func antigravityTitles(_ url: URL) -> [String: String] {
        var titles: [String: String] = [:]
        SQLiteReader(url)?.rows("SELECT conversation_id, title FROM conversation_summaries WHERE title <> ''") { row in
            if let id = row.text(0), let title = row.text(1).flatMap(clean) { titles[id] = title }
        }
        return titles
    }
}

/// Read-only queries on a database another app keeps writing to. Antigravity's are in WAL mode, so reading doesn't
/// hold up its writes.
final class SQLiteReader {
    private var db: OpaquePointer?

    init?(_ url: URL) {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            // A failed open still allocates a handle; `deinit` closes it (and only it, once).
            return nil
        }
        sqlite3_busy_timeout(db, 500)
    }

    deinit { sqlite3_close(db) }

    struct Row {
        fileprivate let stmt: OpaquePointer

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(stmt, column)) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(stmt, column).map { String(cString: $0) } }
        func blob(_ column: Int32) -> [UInt8] {
            guard let p = sqlite3_column_blob(stmt, column) else { return [] }
            return Array(UnsafeRawBufferPointer(start: p, count: Int(sqlite3_column_bytes(stmt, column))))
        }
    }

    /// Hands each row of `sql` to `row`. False if the query failed (an unknown table, say) or stopped partway.
    @discardableResult
    func rows(_ sql: String, _ row: (Row) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: row(Row(stmt: stmt))
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }
}

/// Just enough of the protobuf wire format to pick fields out of a message by number, without its schema.
struct Proto {
    let bytes: ArraySlice<UInt8>

    init(_ bytes: [UInt8]) { self.bytes = bytes[...] }
    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }

    /// The first field numbered `path[0]` that holds a message, string or bytes, then the same inside it for the rest.
    subscript(_ path: Int...) -> Proto? {
        var m = self
        for number in path {
            var found: ArraySlice<UInt8>?
            m.each { n, _, value in
                if n == number, let value { found = value; return false }
                return true
            }
            guard let found else { return nil }
            m = Proto(found)
        }
        return m
    }

    func varint(_ number: Int) -> UInt64? {
        var found: UInt64?
        each { n, value, _ in
            if n == number, let value { found = value; return false }
            return true
        }
        return found
    }

    var string: String? { String(bytes: bytes, encoding: .utf8) }

    /// A `google.protobuf.Timestamp`.
    var date: Date? {
        guard let seconds = varint(1) else { return nil }
        return Date(timeIntervalSince1970: Double(Int64(bitPattern: seconds)) + Double(varint(2) ?? 0) / 1e9)
    }

    /// Hands each field to `body`, its number and its value: a varint, or the bytes of a length-delimited field
    /// (fixed-width ones are skipped). Stops when `body` returns false, or at anything malformed.
    private func each(_ body: (_ number: Int, _ varint: UInt64?, _ bytes: ArraySlice<UInt8>?) -> Bool) {
        var i = bytes.startIndex
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.endIndex, shift < 64 {
                let b = bytes[i]
                i += 1
                v |= UInt64(b & 0x7F) << shift
                if b < 0x80 { return v }
                shift += 7
            }
            return nil
        }
        while i < bytes.endIndex {
            guard let key = varint() else { return }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = varint(), body(number, v, nil) else { return }
            case 1, 5:
                let width = key & 7 == 1 ? 8 : 4
                guard bytes.endIndex - i >= width else { return }
                i += width
            case 2:
                guard let n = varint(), n <= UInt64(bytes.endIndex - i) else { return }
                let value = bytes[i..<(i + Int(n))]
                i += Int(n)
                guard body(number, nil, value) else { return }
            default:
                return
            }
        }
    }
}
