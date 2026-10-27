import Foundation
import Testing
@testable import SempreCore

/// Fixed to UTC so the expected dates don't depend on the machine running the tests.
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "Z")! }

private func parse(_ text: String) throws -> CSVImport.Result { try CSVImport.parse(text, calendar: utc) }

@Suite("CSV import")
struct CSVImportTests {
    @Test func plainFormat() throws {
        let r = try parse("""
            project,task,start,end
            Alpha,Design,2026-10-01 09:00,2026-10-01 10:30
            Beta,,2026-10-02 14:00:00,2026-10-02 15:00:00
            """)
        #expect(r.rows == [
            .init(project: "Alpha", task: "Design", start: at("2026-10-01T09:00:00"), end: at("2026-10-01T10:30:00")),
            .init(project: "Beta", start: at("2026-10-02T14:00:00"), end: at("2026-10-02T15:00:00")),
        ])
        #expect(r.skipped == 0)
    }

    @Test func togglExport() throws {
        let r = try parse("""
            User,Email,Client,Project,Task,Description,Billable,Start date,Start time,End date,End time,Duration,Tags
            Ana,ana@example.com,Acme,Website,,Header,No,2026-10-01,09:15:00,2026-10-01,11:45:00,02:30:00,
            """)
        #expect(r.rows == [.init(project: "Website", start: at("2026-10-01T09:15:00"), end: at("2026-10-01T11:45:00"))])
    }

    @Test func clockifyExportWithUSDatesAndAMPM() throws {
        let r = try parse("""
            Project,Client,Description,Task,User,Start Date,Start Time,End Date,End Time,Duration (h),Duration (decimal)
            Website,Acme,,Build,Ana,10/01/2026,09:00 AM,10/01/2026,01:30 PM,04:30:00,4.50
            """)
        #expect(r.rows == [.init(project: "Website", task: "Build", start: at("2026-10-01T09:00:00"), end: at("2026-10-01T13:30:00"))])
    }

    /// Clockify's formats follow the user's settings: short US dates with AM/PM, or ISO dates with 24-hour times.
    @Test func clockifyExportWithShortYearsAndMixedTimes() throws {
        let r = try parse("""
            Start Date,Start Time,End Date,End Time,Duration (h),Duration (decimal),Project
            7/27/22,1:00 PM,2022-07-27,21:00,08:00:00,8.00,Website
            """)
        #expect(r.rows == [.init(project: "Website", start: at("2022-07-27T13:00:00"), end: at("2022-07-27T21:00:00"))])
    }

    @Test func harvestDetailedExport() throws {
        let r = try parse("""
            Date,Client,Project,Project Code,Task,Notes,Hours,Hours Rounded,Billable?,Invoiced?,Approved?,First Name,Last Name,Roles,Employee?,Billable Rate,Billable Amount,Cost Rate,Cost Amount,Currency,External Reference URL
            8/25/2023,Acme,Website,WEB,Design,"First I did this, then I did that",7.5,7.5,Yes,No,No,Ana,Lee,,Yes,100,750,0,0,US Dollar - USD,
            """)
        #expect(r.rows == [.init(project: "Website", task: "Design", start: at("2023-08-25T09:00:00"), end: at("2023-08-25T16:30:00"))])
    }

    /// Timing exports nested projects as one name, levels joined by " ▸ ".
    @Test func timingExportWithNestedProjects() throws {
        let r = try parse("""
            Day,Duration,Start Date,End Date,Project,Title,Notes
            2026-10-01,5400,2026-10-01T09:00:00+02:00,2026-10-01T10:30:00+02:00,Clients ▸ Acme,Kickoff,
            """)
        #expect(r.rows == [.init(project: "Clients ▸ Acme", start: at("2026-10-01T07:00:00"), end: at("2026-10-01T08:30:00"))])
    }

    @Test func dateAndHoursAreLaidEndToEndFromNine() throws {
        let r = try parse("""
            Date,Client,Project,Task,Notes,Hours
            2026-10-01,Acme,Alpha,Design,,1.5
            2026-10-01,Acme,Beta,,,2
            2026-10-02,Acme,Alpha,,,0.25
            """)
        #expect(r.rows.map(\.start) == [at("2026-10-01T09:00:00"), at("2026-10-01T10:30:00"), at("2026-10-02T09:00:00")])
        #expect(r.rows.map(\.end) == [at("2026-10-01T10:30:00"), at("2026-10-01T12:30:00"), at("2026-10-02T09:15:00")])
    }

    @Test func germanHeadersSemicolonsAndDates() throws {
        let r = try parse("""
            Projekt;Aufgabe;Datum;Von;Bis
            Alpha;Konzept;01.10.2026;09:00;17:30
            Beta;;2.10.26;08:00;
            """)
        #expect(r.rows == [.init(project: "Alpha", task: "Konzept", start: at("2026-10-01T09:00:00"), end: at("2026-10-01T17:30:00"))])
        #expect(r.skipped == 1)
    }

    @Test func durationColumnInsteadOfEnd() throws {
        let r = try parse("""
            Project\tStart\tDuration
            Alpha\t2026-10-01 09:00\t1:45
            Beta\t2026-10-01 12:00\t0,5
            """)
        #expect(r.rows.map(\.end) == [at("2026-10-01T10:45:00"), at("2026-10-01T12:30:00")])
    }

    @Test func endBeforeStartRunsPastMidnight() throws {
        let r = try parse("""
            project,date,start time,end time
            Alpha,2026-10-01,22:00,01:30
            """)
        #expect(r.rows == [.init(project: "Alpha", start: at("2026-10-01T22:00:00"), end: at("2026-10-02T01:30:00"))])
    }

    @Test func timestampsWithTimeZones() throws {
        let r = try parse("""
            project,start,end
            Alpha,2026-10-01T09:00:00+02:00,2026-10-01T10:00:00.250+02:00
            Beta,2026-10-01 09:00:00 -0500,2026-10-01 10:00:00 -0500
            """)
        #expect(r.rows.map(\.start) == [at("2026-10-01T07:00:00"), at("2026-10-01T14:00:00")])
        #expect(abs(r.rows[0].end.timeIntervalSince(at("2026-10-01T08:00:00")) - 0.25) < 0.001)
        #expect(r.rows[1].end == at("2026-10-01T15:00:00"))
    }

    @Test func slashDatesAreDayFirstWhenAnyDateNeedsIt() throws {
        let r = try parse("""
            project,start,end
            Alpha,03/04/2026 09:00,03/04/2026 10:00
            Alpha,13/04/2026 09:00,13/04/2026 10:00
            """)
        #expect(r.rows.map(\.start) == [at("2026-04-03T09:00:00"), at("2026-04-13T09:00:00")])
    }

    @Test func quotedFieldsAndByteOrderMark() throws {
        let r = try parse("\u{FEFF}project,task,start,end\r\n\"Acme, Inc.\",\"The \"\"big\"\" one\",2026-10-01 09:00,2026-10-01 10:00\r\n")
        #expect(r.rows.first?.project == "Acme, Inc.")
        #expect(r.rows.first?.task == "The \"big\" one")
    }

    @Test func unusableRowsAreSkippedAndCounted() throws {
        let r = try parse("""
            project,start,end
            ,2026-10-01 09:00,2026-10-01 10:00
            Alpha,2026-10-01 09:00,
            Alpha,yesterday,today
            Alpha,2026-10-01 10:00,2026-10-01 09:00
            """)
        #expect(r.rows == [.init(project: "No Project", start: at("2026-10-01T09:00:00"), end: at("2026-10-01T10:00:00"))])
        #expect(r.skipped == 3)
    }

    @Test func missingColumnsAreReported() {
        #expect(throws: CSVImport.ImportError.self) { try parse("start,end\n2026-10-01 09:00,2026-10-01 10:00") }
        #expect(throws: CSVImport.ImportError.self) { try parse("project,end\nAlpha,2026-10-01 10:00") }
        #expect(throws: CSVImport.ImportError.self) { try parse("project,start\nAlpha,2026-10-01 09:00") }
        #expect(throws: CSVImport.ImportError.self) { try parse("") }
    }

    @Test func readsWindows1252Files() throws {
        let url = tempDir().appendingPathComponent("export.csv")
        try "project,start,end\nCaf\u{E9},2026-10-01 09:00,2026-10-01 10:00\n".data(using: .windowsCP1252)!.write(to: url)
        #expect(try CSVImport.read(url, calendar: utc).rows.first?.project == "Café")
    }
}

@MainActor
@Suite("Importing entries")
struct ImportEntriesTests {
    let rows = [
        CSVImport.Row(project: "Alpha", task: "Design", start: at("2026-10-01T09:00:00"), end: at("2026-10-01T10:00:00")),
        CSVImport.Row(project: "alpha ", task: "design", start: at("2026-10-01T11:00:00"), end: at("2026-10-01T12:00:00")),
        CSVImport.Row(project: "Beta", start: at("2026-10-01T13:00:00"), end: at("2026-10-01T14:00:00")),
    ]

    @Test func createsProjectsAndSubprojectsByName() {
        let store = Store(fileURL: tempDataFile())
        let n = store.importEntries(rows)
        #expect(n.projects == 2 && n.entries == 3)
        #expect(store.library.projects.map(\.name) == ["Alpha", "Beta"])
        #expect(store.library.subprojects.map(\.name) == ["Design"])
        #expect(store.library.entries.filter { $0.subprojectID != nil }.count == 2)
    }

    @Test func importingTwiceAddsNothingTheSecondTime() {
        let store = Store(fileURL: tempDataFile())
        store.importEntries(rows)
        let again = store.importEntries(rows)
        #expect(again.projects == 0 && again.entries == 0)
        #expect(store.library.entries.count == 3)
    }

    @Test func usesExistingProjects() throws {
        let store = Store(fileURL: tempDataFile())
        let beta = try #require(store.addProject("BETA"))
        let n = store.importEntries([rows[2]])
        #expect(n.projects == 0)
        #expect(store.library.entries.first?.projectID == beta.id)
    }
}
