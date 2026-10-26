import Foundation
import SQLite3
import Testing
@testable import SempreCore

/// Builds a small database with Tyme 2's Core Data schema. All names are made up.
enum FakeTyme {
    static let t0: Double = 800_000_000 // seconds since 2001, like Core Data

    static func make(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw TymeImporter.ImportError(message: "open") }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
        INSERT INTO Z_PRIMARYKEY VALUES (1,'AData',0,0),(2,'ATask',1,0),(6,'TimedTask',2,0),(7,'TimedSubTask',6,0),(8,'Project',1,0),(12,'TimedTaskRecord',9,0);
        CREATE TABLE ZADATA (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZSORTINDEX INTEGER, ZRELATEDPROJECT INTEGER,
                             ZRELATEDTASK INTEGER, ZCOLOR INTEGER, ZCOMPLETEDDATE TIMESTAMP, ZNAME VARCHAR, ZUNIQUEID VARCHAR);
        INSERT INTO ZADATA VALUES
          (1, 8, 0, NULL, NULL, 1122867, NULL, 'Alpha', 'P-ALPHA'),
          (2, 8, 1, NULL, NULL, 16711680, \(t0), 'Beta', 'P-BETA'),
          (10, 6, 0, 1, NULL, NULL, NULL, 'Design', 'T-DESIGN'),
          (11, 6, 0, 2, NULL, NULL, \(t0), 'Build', 'T-BUILD'),
          (20, 7, 0, NULL, 10, NULL, NULL, 'Sketches', 'S-SKETCH');
        CREATE TABLE ZATASKRECORD (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZRELATEDTASK INTEGER,
                                   ZTIMESTART TIMESTAMP, ZTIMEEND TIMESTAMP, ZUNIQUEID VARCHAR);
        INSERT INTO ZATASKRECORD VALUES
          (1, 12, 10, \(t0), \(t0 + 3600), 'R1'),
          (2, 12, 11, \(t0 + 7200), \(t0 + 9000), 'R2'),
          (3, 12, 20, \(t0 + 10000), \(t0 + 10900), 'R3'),
          (4, 12, 10, \(t0 + 20000), \(t0 + 20000), 'R4-zero'),
          (5, 12, 999, \(t0), \(t0 + 60), 'R5-orphan');
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw TymeImporter.ImportError(message: String(cString: sqlite3_errmsg(db)))
        }
    }
}

@Suite("Tyme 2 import")
struct TymeImporterTests {
    func fixture() throws -> URL {
        let dir = tempDir()
        try FakeTyme.make(at: dir.appendingPathComponent("Tyme2.data"))
        return dir
    }

    @Test func importsProjectsWithColourAndArchiveState() throws {
        let r = try TymeImporter.importFrom(fixture())
        #expect(r.projects.map(\.name) == ["Alpha", "Beta"])
        #expect(r.projects[0].rgb == 0x112233)
        #expect(r.projects[0].archived == false)
        #expect(r.projects[1].archived == true)
        #expect(r.projects.map(\.tymeID) == ["P-ALPHA", "P-BETA"])
    }

    @Test func tasksBecomeSubprojects() throws {
        let r = try TymeImporter.importFrom(fixture())
        let alpha = r.projects[0], beta = r.projects[1]
        #expect(r.subprojects.map(\.name) == ["Design", "Build"])
        #expect(r.subprojects[0].projectID == alpha.id)
        #expect(r.subprojects[1].projectID == beta.id)
        #expect(r.subprojects[1].archived)
    }

    @Test func recordsMapToProjectAndSubproject() throws {
        let r = try TymeImporter.importFrom(fixture())
        let design = try #require(r.subprojects.first { $0.name == "Design" })
        // Zero-length and orphaned records are skipped.
        #expect(r.entries.map(\.tymeID) == ["R1", "R2", "R3"])
        #expect(r.entries[0].start == Date(timeIntervalSinceReferenceDate: FakeTyme.t0))
        #expect(r.entries[0].worked(now: Date()) == 3600)
        // A record on a Tyme subtask rolls up into its task.
        #expect(r.entries[2].subprojectID == design.id)
        #expect(r.entries[2].projectID == r.projects[0].id)
    }

    @Test func acceptsTheDatabaseFileDirectly() throws {
        let r = try TymeImporter.importFrom(fixture().appendingPathComponent("Tyme2.data"))
        #expect(r.entries.count == 3)
    }

    @Test func prefersTheLiveStoreOverBackups() throws {
        let dir = tempDir()
        let backups = dir.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try FakeTyme.make(at: backups.appendingPathComponent("Tyme2_2026-10-01.data"))
        try FakeTyme.make(at: dir.appendingPathComponent("Tyme2.data"))
        #expect(try TymeImporter.databaseFile(at: dir) == dir.appendingPathComponent("Tyme2.data"))
    }

    @Test func findsTheStoreInASubfolder() throws {
        let dir = tempDir()
        let nested = dir.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FakeTyme.make(at: nested.appendingPathComponent("Tyme2.data"))
        #expect(try TymeImporter.databaseFile(at: dir)?.lastPathComponent == "Tyme2.data")
    }

    @Test func leavesTymesFilesUntouched() throws {
        let dir = try fixture()
        let file = dir.appendingPathComponent("Tyme2.data")
        let before = try Data(contentsOf: file)
        _ = try TymeImporter.importFrom(dir)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func folderWithoutTymeDataFails() {
        #expect(throws: TymeImporter.ImportError.self) { try TymeImporter.importFrom(tempDir()) }
    }

    @Test func otherSQLiteFilesAreRejected() throws {
        let file = tempDir().appendingPathComponent("Tyme2.data")
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        sqlite3_exec(db, "CREATE TABLE notes (id INTEGER);", nil, nil, nil)
        sqlite3_close(db)
        #expect(throws: TymeImporter.ImportError.self) { try TymeImporter.importFrom(file) }
    }
}
