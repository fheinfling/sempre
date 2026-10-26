import Foundation
import SQLite3

/// Reads Tyme 2's Core Data SQLite store and maps every time record to its project.
public enum TymeImporter {
    public struct Result {
        public var projects: [Project]
        public var subprojects: [Subproject]
        public var entries: [Entry]
    }

    public struct ImportError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Where Tyme 2 keeps its data on a Mac.
    public static let defaultLocation = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/de.lgerckens.Tyme2/Data/Library/Application Support")

    /// Imports from Tyme's data folder or its `Tyme2.data` file. Tyme's files are copied first, never modified.
    public static func importFrom(_ url: URL) throws -> Result {
        guard let file = try databaseFile(at: url) else {
            throw ImportError(message: "No Tyme2.data found in \(url.lastPathComponent).")
        }
        return try read(file)
    }

    /// The live store is `Tyme2.data`; dated copies in `Backups/` are ignored.
    static func databaseFile(at url: URL) throws -> URL? {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard isDir.boolValue else { return url }
        let direct = url.appendingPathComponent("Tyme2.data")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        while let f = e?.nextObject() as? URL {
            if f.lastPathComponent == "Tyme2.data" { return f }
        }
        return nil
    }

    // MARK: SQLite

    private final class DB {
        var handle: OpaquePointer?
        /// The copy holds the user's whole Tyme history, so deinit deletes it again (also when init throws).
        private let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sempre-import-\(UUID().uuidString)")

        init(_ url: URL) throws {
            // Work on a copy so we never touch Tyme's live store (and include WAL changes).
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let dst = tmp.appendingPathComponent(url.lastPathComponent)
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: url.path + suffix)
                // Copy raw bytes only; Tyme's container files carry attributes copyItem can't reproduce.
                if FileManager.default.fileExists(atPath: src.path) {
                    try Data(contentsOf: src).write(to: URL(fileURLWithPath: dst.path + suffix))
                }
            }
            guard sqlite3_open_v2(dst.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                throw ImportError(message: "Could not open \(url.lastPathComponent).")
            }
        }
        deinit {
            sqlite3_close(handle)
            try? FileManager.default.removeItem(at: tmp)
        }

        func rows(_ sql: String) -> [[String: Any]] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [[String: Any]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: Any] = [:]
                for i in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, i)).uppercased()
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                    case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                    default: break
                    }
                }
                out.append(row)
            }
            return out
        }

        func tables() -> [String] {
            rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["NAME"] as? String }
        }

        func columns(_ table: String) -> [String] {
            rows("PRAGMA table_info(\"\(table)\")").compactMap { ($0["NAME"] as? String)?.uppercased() }
        }
    }

    /// Tyme 2 (Core Data) keeps projects and tasks in ZADATA, told apart by Z_ENT.
    /// Time records point at a task (ZRELATEDTASK), tasks point at a project (ZRELATEDPROJECT).
    private static func read(_ url: URL) throws -> Result {
        let db = try DB(url)
        guard Set(db.tables()).isSuperset(of: ["ZADATA", "ZATASKRECORD", "Z_PRIMARYKEY"]) else {
            throw ImportError(message: "\(url.lastPathComponent) isn't a Tyme 2 database.")
        }
        let entities = db.rows("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY")
        guard let projectEnt = entities.first(where: { $0["Z_NAME"] as? String == "Project" })?["Z_ENT"] as? Int else {
            throw ImportError(message: "No projects found in \(url.lastPathComponent).")
        }

        var projects: [Project] = []
        var byPK: [Int: UUID] = [:]
        for row in db.rows("SELECT Z_PK, ZNAME, ZCOLOR, ZUNIQUEID, ZCOMPLETEDDATE FROM ZADATA WHERE Z_ENT = \(projectEnt) ORDER BY ZSORTINDEX") {
            guard let pk = row["Z_PK"] as? Int, let name = row["ZNAME"] as? String else { continue }
            var p = Project(name: name, color: projects.count, archived: row["ZCOMPLETEDDATE"] != nil)
            p.rgb = row["ZCOLOR"] as? Int
            p.tymeID = row["ZUNIQUEID"] as? String ?? "pk-\(pk)"
            projects.append(p)
            byPK[pk] = p.id
        }

        // Tasks become subprojects; Tyme's own subtasks roll up into their task.
        var subprojects: [Subproject] = []
        var taskTo: [Int: (project: UUID, sub: UUID)] = [:]
        for row in db.rows("SELECT Z_PK, ZNAME, ZRELATEDPROJECT, ZUNIQUEID, ZCOMPLETEDDATE FROM ZADATA WHERE Z_ENT <> \(projectEnt) AND ZRELATEDPROJECT IS NOT NULL") {
            guard let pk = row["Z_PK"] as? Int, let proj = row["ZRELATEDPROJECT"] as? Int, let pid = byPK[proj] else { continue }
            let sub = Subproject(projectID: pid, name: row["ZNAME"] as? String ?? "Task",
                                 archived: row["ZCOMPLETEDDATE"] != nil, tymeID: row["ZUNIQUEID"] as? String ?? "pk-\(pk)")
            subprojects.append(sub)
            taskTo[pk] = (pid, sub.id)
        }
        for row in db.rows("SELECT Z_PK, ZRELATEDTASK FROM ZADATA WHERE ZRELATEDPROJECT IS NULL AND ZRELATEDTASK IS NOT NULL") {
            if let pk = row["Z_PK"] as? Int, let parent = row["ZRELATEDTASK"] as? Int, let t = taskTo[parent] { taskTo[pk] = t }
        }

        var entries: [Entry] = []
        for row in db.rows("SELECT Z_PK, ZRELATEDTASK, ZTIMESTART, ZTIMEEND, ZUNIQUEID FROM ZATASKRECORD") {
            guard let task = row["ZRELATEDTASK"] as? Int, let t = taskTo[task],
                  let start = date(row["ZTIMESTART"]), let end = date(row["ZTIMEEND"]), end > start else { continue }
            let rid = row["ZUNIQUEID"] as? String ?? "pk-\(row["Z_PK"] as? Int ?? entries.count)"
            entries.append(Entry(projectID: t.project, subprojectID: t.sub, start: start, end: end, tymeID: rid))
        }
        if entries.isEmpty { throw ImportError(message: "Found \(projects.count) projects but no time records.") }
        return Result(projects: projects, subprojects: subprojects, entries: entries)
    }

    /// Core Data stores dates as seconds since 2001-01-01.
    private static func date(_ v: Any?) -> Date? {
        if let d = v as? Double { return Date(timeIntervalSinceReferenceDate: d) }
        if let i = v as? Int { return Date(timeIntervalSinceReferenceDate: TimeInterval(i)) }
        return nil
    }
}
