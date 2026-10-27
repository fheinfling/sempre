import Foundation
import Testing
@testable import SempreCore

@MainActor
@Suite("Store")
struct StoreTests {
    let now = Date()

    @Test func startAndStopRecordsAnEntry() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        store.addEntry(projectID: a.id, subprojectID: nil, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-600))
        store.start(a)
        #expect(store.running?.projectID == a.id)
        #expect(store.isRunning(a.id))
        #expect(store.library.entries.count == 2)
    }

    @Test func misClickUnderTenSecondsIsDropped() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        store.start(a)
        store.stop()
        #expect(store.library.entries.isEmpty)
        #expect(store.running == nil)
    }

    @Test func restartWithinAMinuteContinuesTheEntry() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        store.addEntry(projectID: a.id, subprojectID: nil, start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-30))
        store.start(a)
        #expect(store.library.entries.count == 1)
        #expect(store.running?.start == store.library.entries[0].start)
        store.stop()
        #expect(store.library.entries.count == 1)
        #expect(store.library.entries[0].worked(now: Date()) >= 599)
    }

    @Test func restartAfterTwoMinutesStartsANewEntry() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        store.addEntry(projectID: a.id, subprojectID: nil, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-120))
        store.start(a)
        #expect(store.library.entries.count == 2)
    }

    @Test func otherProjectWithinAMinuteStartsANewEntry() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        let b = try #require(store.addProject("Beta"))
        store.addEntry(projectID: a.id, subprojectID: nil, start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-30))
        store.start(b)
        #expect(store.library.entries.count == 2)
        #expect(store.running?.projectID == b.id)
    }

    @Test func toggleStartsAndStops() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        let sub = try #require(store.addSubproject("Design", to: a.id))
        store.toggle(a, sub)
        #expect(store.isRunning(a.id))
        #expect(store.isRunning(a.id, sub.id))
        store.toggle(a, sub)
        #expect(store.running == nil)
    }

    @Test func startingAnotherProjectStopsTheRunningOne() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        let b = try #require(store.addProject("Beta"))
        store.updateEntry(UUID(), start: now, end: nil, subprojectID: nil) // unknown id: no-op
        store.addEntry(projectID: a.id, subprojectID: nil, start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-300))
        store.start(a)
        store.start(b)
        #expect(store.library.entries.filter { $0.end == nil }.count == 1)
        #expect(store.running?.projectID == b.id)
    }

    @Test func archiveHidesTheProjectAndStopsItsTimer() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        store.start(a)
        store.archive(a.id)
        #expect(store.running == nil)
        #expect(store.projects.isEmpty)
        #expect(store.allProjects.map(\.name) == ["Alpha"])
    }

    @Test func deleteProjectRemovesItsEntriesAndSubprojects() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        let b = try #require(store.addProject("Beta"))
        store.addSubproject("Design", to: a.id)
        store.addEntry(projectID: a.id, subprojectID: nil, start: now.addingTimeInterval(-3600), end: now)
        store.addEntry(projectID: b.id, subprojectID: nil, start: now.addingTimeInterval(-3600), end: now)
        store.delete(a.id)
        #expect(store.library.projects.map(\.name) == ["Beta"])
        #expect(store.library.subprojects.isEmpty)
        #expect(store.library.entries.map(\.projectID) == [b.id])
    }

    @Test func deleteEntries() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        for h in 1...3 {
            store.addEntry(projectID: a.id, subprojectID: nil, start: now.addingTimeInterval(Double(-h) * 3600), end: now.addingTimeInterval(Double(-h) * 3600 + 600))
        }
        let ids = Set(store.library.entries.prefix(2).map(\.id))
        store.deleteEntries(ids)
        #expect(store.library.entries.count == 1)
        store.deleteEntry(store.library.entries[0].id)
        #expect(store.library.entries.isEmpty)
    }

    @Test func updateEntryChangesTimesBreaksAndKeepsOrder() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        store.addEntry(projectID: a.id, subprojectID: nil, start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        store.addEntry(projectID: a.id, subprojectID: nil, start: now.addingTimeInterval(-3000), end: now.addingTimeInterval(-1000))
        let late = store.library.entries[1]
        store.updateEntry(late.id, start: now.addingTimeInterval(-10_000), end: now.addingTimeInterval(-9000),
                          subprojectID: nil, breaks: [Break(duration: 600)])
        #expect(store.library.entries.first?.id == late.id)
        #expect(store.library.entries.first?.breakTotal == 600)
        // An empty break list clears breaks.
        store.updateEntry(late.id, start: now.addingTimeInterval(-10_000), end: now.addingTimeInterval(-9000), subprojectID: nil, breaks: [])
        #expect(store.library.entries.first?.breaks == nil)
    }

    @Test func totalsAndBreakdown() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        let b = try #require(store.addProject("Beta"))
        store.addEntry(projectID: a.id, subprojectID: nil, start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        store.addEntry(projectID: b.id, subprojectID: nil, start: now.addingTimeInterval(-1800), end: now)
        let iv = DateInterval(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(60))
        #expect(store.total(in: iv) == 5400)
        #expect(store.total(for: a.id, in: iv) == 3600)
        #expect(store.breakdown(in: iv).map(\.project.name) == ["Alpha", "Beta"])
        #expect(store.entries(of: a.id, in: iv).count == 1)
    }

    @Test func projectsAreSortedByMostRecentUse() throws {
        let store = Store(fileURL: tempDataFile())
        let a = try #require(store.addProject("Alpha"))
        let b = try #require(store.addProject("Beta"))
        store.addEntry(projectID: a.id, subprojectID: nil, start: now.addingTimeInterval(-600), end: now)
        store.addEntry(projectID: b.id, subprojectID: nil, start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-6000))
        #expect(store.projects.map(\.name) == ["Alpha", "Beta"])
    }

    @Test func emptyNamesAreRejected() {
        let store = Store(fileURL: tempDataFile())
        #expect(store.addProject("   ") == nil)
        #expect(store.library.projects.isEmpty)
    }
}

@MainActor
@Suite("Persistence and sync")
struct PersistenceTests {
    @Test func dataSurvivesARestart() throws {
        let file = tempDataFile()
        let first = Store(fileURL: file)
        let a = try #require(first.addProject("Alpha"))
        first.addSubproject("Design", to: a.id)
        first.addEntry(projectID: a.id, subprojectID: nil, start: Date().addingTimeInterval(-3600), end: Date(),
                       breaks: [Break(duration: 300)])

        let second = Store(fileURL: file)
        #expect(second.library.projects.map(\.id) == [a.id])
        #expect(second.library.subprojects.map(\.name) == ["Design"])
        #expect(second.library.entries.first?.breakTotal == 300)
    }

    @Test func readsFilesWrittenBeforeSubprojectsAndBreaks() throws {
        let file = tempDataFile()
        let pid = UUID()
        let json = """
        {
          "projects": [{ "id": "\(pid)", "name": "Alpha", "color": 2, "archived": false }],
          "entries": [{ "id": "\(UUID())", "projectID": "\(pid)", "start": "2026-10-01T08:00:00Z", "end": "2026-10-01T10:00:00Z" }]
        }
        """
        try json.write(to: file, atomically: true, encoding: .utf8)
        let store = Store(fileURL: file)
        #expect(store.lastError == nil)
        #expect(store.library.projects.first?.name == "Alpha")
        #expect(store.library.subprojects.isEmpty)
        #expect(store.library.entries.first?.worked(now: Date()) == 7200)
    }

    @Test func picksUpChangesFromAnotherMac() throws {
        let file = tempDataFile()
        let mine = Store(fileURL: file)
        _ = try #require(mine.addProject("Alpha"))

        // Another Mac writes the file through iCloud Drive.
        let other = Store(fileURL: file)
        other.addProject("Beta")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)

        mine.reloadIfChanged()
        #expect(mine.library.projects.map(\.name) == ["Alpha", "Beta"])
    }

    @Test func unreadableFileIsReportedNotOverwritten() throws {
        let file = tempDataFile()
        try "not json".write(to: file, atomically: true, encoding: .utf8)
        let store = Store(fileURL: file)
        #expect(store.lastError != nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
    }

    @Test func movesTempoDataToSempreOnce() throws {
        let root = tempDir()
        let legacy = root.appendingPathComponent("Tempo/tempo.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"projects":[],"entries":[]}"#.write(to: legacy, atomically: true, encoding: .utf8)

        let file = Store.dataFile(in: root)
        #expect(file == root.appendingPathComponent("Sempre/sempre.json"))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.deletingLastPathComponent().path))
    }

    @Test func existingSempreDataWinsOverLegacy() throws {
        let root = tempDir()
        let file = root.appendingPathComponent("Sempre/sempre.json")
        let legacy = root.appendingPathComponent("Tempo/tempo.json")
        for url in [file, legacy] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try url.lastPathComponent.write(to: url, atomically: true, encoding: .utf8)
        }
        _ = Store.dataFile(in: root)
        #expect(try String(contentsOf: file, encoding: .utf8) == "sempre.json")
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }
}
