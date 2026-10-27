import Foundation

/// Reads time entries from a CSV file, as exported by most time trackers (Toggl, Clockify, Harvest, Timing, …).
/// Columns are found by their header names; README › Import from other apps lists the names it understands.
public enum CSVImport {
    public struct Row: Equatable {
        public var project: String
        public var task: String?
        public var start: Date
        public var end: Date

        public init(project: String, task: String? = nil, start: Date, end: Date) {
            self.project = project
            self.task = task
            self.start = start
            self.end = end
        }
    }

    public struct Result {
        public var rows: [Row]
        /// Lines without a usable start and end (running timers, blank times, unreadable dates).
        public var skipped: Int
    }

    public struct ImportError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What a column holds. A cell may carry a date, a time or both; missing parts come from the other columns.
    enum Column: CaseIterable {
        case project, task, date, start, startTime, end, endTime, duration

        /// Header names, lowercased with everything but letters and digits removed ("Duration (h)" → "durationh").
        var names: [String] {
            switch self {
            case .project: ["project", "projectname", "projekt"]
            case .task: ["task", "taskname", "subproject", "aufgabe"]
            case .date: ["date", "day", "datum"]
            case .start: ["start", "startdate", "startedat", "begin", "from", "beginn", "von"]
            case .startTime: ["starttime", "startzeit"]
            case .end: ["end", "enddate", "endedat", "stop", "to", "ende", "bis"]
            case .endTime: ["endtime", "stoptime", "endzeit"]
            case .duration: ["duration", "durationh", "durationdecimal", "hours", "dauer", "stunden"]
            }
        }
    }

    /// Entries with a date but no time of day are laid end to end from this hour.
    static let dayStartHour = 9

    /// Reads UTF-8 (the usual export), UTF-16 with a byte-order mark, or Windows-1252 (older Excel).
    public static func read(_ url: URL, calendar: Calendar = .current) throws -> Result {
        let data = try Data(contentsOf: url)
        let bom = data.prefix(2)
        let text = String(data: data, encoding: .utf8)
            ?? (bom == Data([0xFF, 0xFE]) || bom == Data([0xFE, 0xFF]) ? String(data: data, encoding: .utf16) : nil)
            ?? String(data: data, encoding: .windowsCP1252)
        guard let text else { throw ImportError(message: "\(url.lastPathComponent) isn't a text file.") }
        return try parse(text, calendar: calendar)
    }

    public static func parse(_ text: String, calendar: Calendar = .current) throws -> Result {
        var records = records(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        records.removeAll { $0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !records.isEmpty else { throw ImportError(message: "The file is empty.") }

        let header = records.removeFirst().map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        var index: [Column: Int] = [:]
        for column in Column.allCases {
            index[column] = header.firstIndex { column.names.contains($0) }
        }
        guard index[.project] != nil else { throw ImportError(message: "No “Project” column found.") }
        guard index[.date] != nil || index[.start] != nil else { throw ImportError(message: "No “Start” or “Date” column found.") }
        guard index[.end] != nil || index[.endTime] != nil || index[.duration] != nil else {
            throw ImportError(message: "No “End” or “Duration” column found.")
        }

        // 03/04/2026 is 4 March unless some date in the file only works day-first (13/04/2026).
        let dateColumns = [Column.date, .start, .end].compactMap { index[$0] }
        let dayFirst = records.contains { r in
            dateColumns.contains { $0 < r.count && (r[$0].firstMatch(of: slashDate).map { Int($0.1)! > 12 } ?? false) }
        }

        var rows: [Row] = []
        var skipped = 0
        var nextFree: [Date: Date] = [:]
        for r in records {
            func cell(_ c: Column) -> String? {
                guard let i = index[c], i < r.count else { return nil }
                let s = r[i].trimmingCharacters(in: .whitespaces)
                return s.isEmpty ? nil : s
            }
            func moment(_ c: Column) -> Moment? { cell(c).flatMap { Moment($0, dayFirst: dayFirst) } }
            let date = moment(.date), s = moment(.start), st = moment(.startTime)
            let e = moment(.end), et = moment(.endTime)
            let duration = cell(.duration).flatMap(Self.duration)

            var start: Date?
            var end: Date?
            if let absolute = s?.absolute {
                start = absolute
            } else if let day = s?.day ?? date?.day {
                if let time = s?.time ?? st?.time {
                    start = Moment.combine(day, time, calendar)
                } else if let duration, let midnight = calendar.date(from: day) {
                    // A date and hours only (Harvest and the like): place entries one after another.
                    let from = nextFree[midnight] ?? calendar.date(byAdding: .hour, value: dayStartHour, to: midnight)!
                    start = from
                    end = from.addingTimeInterval(duration)
                    nextFree[midnight] = end
                }
            }
            if let start, end == nil {
                if let absolute = e?.absolute {
                    end = absolute
                } else if let time = e?.time ?? et?.time {
                    let explicitDay = e?.day ?? et?.day
                    let day = explicitDay ?? calendar.dateComponents([.year, .month, .day], from: start)
                    end = Moment.combine(day, time, calendar)
                    // An end time before the start without its own date ran past midnight.
                    if explicitDay == nil, let t = end, t <= start { end = calendar.date(byAdding: .day, value: 1, to: t) }
                } else if let duration {
                    end = start.addingTimeInterval(duration)
                }
            }
            guard let start, let end, end > start else { skipped += 1; continue }
            rows.append(Row(project: cell(.project) ?? "No Project", task: cell(.task), start: start, end: end))
        }
        if rows.isEmpty { throw ImportError(message: "No time entries found (\(skipped) rows without a usable start and end).") }
        return Result(rows: rows, skipped: skipped)
    }

    /// "1:30", "1:30:00", "1.5" or "1,5" (hours).
    static func duration(_ s: String) -> TimeInterval? {
        if s.contains(":") {
            let parts = s.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard (2...3).contains(parts.count), !parts.contains(nil) else { return nil }
            let p = parts.map { $0! }
            return TimeInterval(p[0] * 3600 + p[1] * 60 + (p.count == 3 ? p[2] : 0))
        }
        return Double(s.replacingOccurrences(of: ",", with: ".")).map { $0 * 3600 }
    }

    // MARK: CSV

    /// Splits CSV text into records. Handles quoted fields (with "" for a quote, and line breaks inside),
    /// and takes whichever of comma, semicolon or tab the header line uses most as the separator.
    static func records(_ text: String) -> [[String]] {
        let firstLine = text.prefix { !$0.isNewline }
        let candidates: [Character] = [",", ";", "\t"]
        let separator = candidates.max { a, b in
            firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
        }!
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending: Character?
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    let next = chars.next()
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                record.append(field)
                field = ""
            } else if c.isNewline {
                record.append(field)
                records.append(record)
                record = []
                field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }
}

// MARK: Dates

private let isoDate = #/(\d{4})-(\d{1,2})-(\d{1,2})/#
private let dotDate = #/(\d{1,2})\.(\d{1,2})\.(\d{2,4})/#
private let slashDate = #/(\d{1,2})/(\d{1,2})/(\d{2,4})/#
private let clockTime = #/(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*([AaPp]\.?[Mm]\.?)?(?:\s*(Z|[+-]\d{2}:?\d{2}))?/#

/// The date and/or time of day found in one cell; an ISO 8601 timestamp with a time zone is taken as is.
struct Moment {
    var day: DateComponents?
    var time: DateComponents?
    var absolute: Date?

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions.insert(.withFractionalSeconds)
        return f
    }()

    init?(_ s: String, dayFirst: Bool) {
        if let d = Moment.iso.date(from: s) ?? Moment.isoFractional.date(from: s) {
            absolute = d
            return
        }
        var rest = Substring(s)
        if let m = s.firstMatch(of: isoDate) {
            day = DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3))
            rest = s[m.range.upperBound...]
        } else if let m = s.firstMatch(of: dotDate) {
            day = DateComponents(year: Moment.year(m.3), month: Int(m.2), day: Int(m.1))
            rest = s[m.range.upperBound...]
        } else if let m = s.firstMatch(of: slashDate) {
            let (a, b) = (Int(m.1)!, Int(m.2)!)
            day = DateComponents(year: Moment.year(m.3), month: dayFirst ? b : a, day: dayFirst ? a : b)
            rest = s[m.range.upperBound...]
        }
        if let d = day, !(1...12).contains(d.month!) || !(1...31).contains(d.day!) { day = nil }

        if let m = rest.firstMatch(of: clockTime) {
            var hour = Int(m.1)!
            if let meridiem = m.4?.lowercased() {
                hour %= 12
                if meridiem.hasPrefix("p") { hour += 12 }
            }
            var t = DateComponents(hour: hour, minute: Int(m.2), second: m.3.flatMap { Int($0) } ?? 0)
            if let zone = m.5 {
                let digits = zone.filter(\.isNumber)
                let seconds = zone == "Z" ? 0 : (Int(digits.prefix(2))! * 3600 + Int(digits.suffix(2))! * 60) * (zone.hasPrefix("-") ? -1 : 1)
                t.timeZone = TimeZone(secondsFromGMT: seconds)
            }
            if hour < 24, t.minute! < 60 { time = t }
        }
        if day == nil && time == nil { return nil }
    }

    private static func year(_ s: Substring) -> Int {
        let y = Int(s)!
        return y < 100 ? 2000 + y : y
    }

    static func combine(_ day: DateComponents, _ time: DateComponents, _ calendar: Calendar) -> Date? {
        var c = day
        c.hour = time.hour
        c.minute = time.minute
        c.second = time.second
        c.timeZone = time.timeZone
        return calendar.date(from: c)
    }
}
