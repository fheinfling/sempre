import Foundation
import Testing
@testable import SempreCore

@Suite("Formatting")
struct FormattingTests {
    @Test func short() {
        #expect(Fmt.short(0) == "0m")
        #expect(Fmt.short(59 * 60 + 59) == "59m")
        #expect(Fmt.short(3600 + 5 * 60) == "1h 05m")
        #expect(Fmt.short(150 * 3600 + 20 * 60) == "150h")
        #expect(Fmt.short(-30) == "0m")
    }

    @Test func clock() {
        #expect(Fmt.clock(3725) == "1:02:05")
        #expect(Fmt.clock(0) == "0:00:00")
    }

    @Test func axis() {
        #expect(Fmt.axis(0) == "0m")
        #expect(Fmt.axis(0.5) == "30m")
        #expect(Fmt.axis(2) == "2h")
        #expect(Fmt.axis(1.5) == "1h30")
    }
}

@Suite("Menu bar text")
struct MenuBarTextTests {
    func label(_ name: String? = "Client", worked: Int, today: Int = 3600, hadBreak: Bool = false) -> String {
        MenuBarText.label(project: name, worked: TimeInterval(worked), today: TimeInterval(today), hadBreak: hadBreak)
    }

    @Test func showsHoursAndMinutes() {
        #expect(label(worked: 65 * 60 + 30) == "Client 1:05")
        #expect(label(nil, worked: 65 * 60 + 30) == "1:05")
    }

    @Test func greetsAtTheStart() {
        #expect(label(worked: 3) == "Client let's go")
        #expect(label(nil, worked: 3) == "let's go")
    }

    @Test func celebratesFullHours() {
        #expect(label(worked: 2 * 3600 + 5) == "Client 2h · nice!")
        #expect(label(worked: 2 * 3600 + 30) == "Client 2:00")
    }

    @Test func suggestsABreakAfterNinetyMinutes() {
        #expect(label(worked: 100 * 60 + 3) == "Client 1:40 · break?")
        #expect(label(worked: 100 * 60 + 3, hadBreak: true) == "Client 1:40")
    }

    @Test func callsItADayAfterEightHours() {
        #expect(label(worked: 65 * 60 + 30, today: 8 * 3600 + 2) == "Feierabend?")
    }

    @Test func showsTodaysProjectTotalWhenAsked() {
        // 20 min on this timer, 2h 05m on the project today.
        #expect(MenuBarText.label(project: "Client", worked: 20 * 60, shown: 125 * 60, today: 3 * 3600, hadBreak: false) == "Client 2:05")
        // The full-hour nudge follows the shown total…
        #expect(MenuBarText.label(project: "Client", worked: 20 * 60, shown: 2 * 3600 + 4, today: 3 * 3600, hadBreak: false) == "Client 2h · nice!")
        // …while "let's go" still follows the timer that just started.
        #expect(MenuBarText.label(project: "Client", worked: 3, shown: 2 * 3600 + 30, today: 3 * 3600, hadBreak: false) == "Client let's go")
    }

    @Test func truncatesLongProjectNames() {
        #expect(label("A very long project name", worked: 65 * 60 + 30) == "A very long pr 1:05")
    }
}

@Suite("Hour marks")
struct HourMarksTests {
    @Test func celebratesEachNewHourOnce() {
        var marks = HourMarks()
        #expect(marks.check(key: "a", seconds: 3590) == nil)   // baseline: 0 h
        #expect(marks.check(key: "a", seconds: 3601) == 1)
        #expect(marks.check(key: "a", seconds: 3700) == nil)   // same hour again
        #expect(marks.check(key: "a", seconds: 7200) == 2)
    }

    @Test func doesNotCelebrateOnFirstSight() {
        var marks = HourMarks()
        #expect(marks.check(key: "a", seconds: 3 * 3600 + 1200) == nil)
        #expect(marks.check(key: "a", seconds: 4 * 3600 + 1) == 4)
    }

    @Test func keysAreIndependent() {
        var marks = HourMarks()
        _ = marks.check(key: "a", seconds: 3500)
        _ = marks.check(key: "b", seconds: 3500)
        #expect(marks.check(key: "a", seconds: 3601) == 1)
        #expect(marks.check(key: "b", seconds: 3599) == nil)
    }
}
