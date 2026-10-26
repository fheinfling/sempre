import Foundation
import Testing
@testable import SempreCore

@Suite("Entry durations and breaks")
struct EntryTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let pid = UUID()
    var wide: DateInterval { DateInterval(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(86_400)) }

    func entry(hoursAgo: Double, endHoursAgo: Double? = 0, breaks: [Break]? = nil) -> Entry {
        Entry(projectID: pid, start: now.addingTimeInterval(-hoursAgo * 3600),
              end: endHoursAgo.map { now.addingTimeInterval(-$0 * 3600) }, breaks: breaks)
    }

    @Test func spanIsTheOverlapWithTheInterval() {
        let e = entry(hoursAgo: 4)
        let lastTwoHours = DateInterval(start: now.addingTimeInterval(-7200), end: now)
        #expect(e.span(in: wide, now: now) == 4 * 3600)
        #expect(e.span(in: lastTwoHours, now: now) == 2 * 3600)
        #expect(e.span(in: DateInterval(start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200)), now: now) == 0)
    }

    @Test func runningEntryCountsUntilNow() {
        let e = entry(hoursAgo: 1.5, endHoursAgo: nil)
        #expect(e.worked(now: now) == 1.5 * 3600)
        #expect(e.duration(in: wide, now: now.addingTimeInterval(600)) == 1.5 * 3600 + 600)
    }

    @Test func lengthBreakIsSubtracted() {
        let e = entry(hoursAgo: 9, breaks: [Break(duration: 3600)])
        #expect(e.worked(now: now) == 8 * 3600)
        #expect(e.breakTotal == 3600)
    }

    @Test func lengthBreakIsSpreadOverPartialIntervals() {
        // 4h entry with a 1h break: half the entry in the interval means half the break.
        let e = entry(hoursAgo: 4, breaks: [Break(duration: 3600)])
        let lastTwoHours = DateInterval(start: now.addingTimeInterval(-7200), end: now)
        #expect(e.duration(in: lastTwoHours, now: now) == 1.5 * 3600)
    }

    @Test func timedBreakOnlyCountsWhereItOverlaps() {
        let lunch = Break(start: now.addingTimeInterval(-3 * 3600), duration: 1800)
        let e = entry(hoursAgo: 9, breaks: [lunch])
        #expect(e.worked(now: now) == 8.5 * 3600)
        // An interval that ends before the break isn't reduced.
        let morning = DateInterval(start: now.addingTimeInterval(-9 * 3600), end: now.addingTimeInterval(-4 * 3600))
        #expect(e.duration(in: morning, now: now) == 5 * 3600)
    }

    @Test func breaksNeverMakeTimeNegative() {
        let e = entry(hoursAgo: 1, breaks: [Break(duration: 7200), Break(start: now.addingTimeInterval(-1800), duration: 3600)])
        #expect(e.worked(now: now) == 0)
    }

    @Test func breaksOnARunningEntry() {
        let e = entry(hoursAgo: 2, endHoursAgo: nil, breaks: [Break(duration: 1800)])
        #expect(e.worked(now: now) == 1.5 * 3600)
    }
}
