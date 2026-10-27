import Foundation

public enum Fmt {
    /// 1:05:03
    public static func clock(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Chart axis label for an hour value: 30m, 2h, 1h30.
    public static func axis(_ hours: Double) -> String {
        let m = Int((hours * 60).rounded())
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h\(m % 60)"
    }

    /// 1h 05m / 12m; whole hours only from 100h on.
    public static func short(_ t: TimeInterval) -> String {
        let m = Int(max(0, t)) / 60
        if m < 60 { return "\(m)m" }
        if m >= 100 * 60 { return "\((m / 60).formatted())h" }
        return String(format: "%dh %02dm", m / 60, m % 60)
    }
}

/// Text next to the menu bar icon while a timer runs.
public enum MenuBarText {
    /// "Client 1:05" (or "1:05" without a project name), or now and then a short nudge instead.
    /// `worked` is the running entry; `shown` is the time to display (e.g. today on this project), defaulting to `worked`.
    /// The clock and the full-hour nudge follow `shown`; the start and break nudges follow the running entry.
    public static func label(project: String?, worked: TimeInterval, shown: TimeInterval? = nil,
                             today: TimeInterval, hadBreak: Bool) -> String {
        let prefix = project.map { String($0.prefix(14)) + " " } ?? ""
        let w = Int(worked), m = w / 60
        let s = Int(shown ?? worked), sm = s / 60
        let t = Int(today)
        let clock = "\(sm / 60):" + String(format: "%02d", sm % 60)
        if w < 6 { return "\(prefix)let's go" }
        if t >= 8 * 3600 && (t / 60) % 15 == 0 && t % 60 < 8 { return "Feierabend?" }
        if sm >= 60 && sm % 60 == 0 && s % 60 < 10 { return "\(prefix)\(sm / 60)h · nice!" }
        if !hadBreak && m >= 90 && m % 20 == 0 && w % 60 < 8 { return "\(prefix)\(clock) · break?" }
        return prefix + clock
    }
}

/// Decides when a full hour has just been reached, so it's celebrated once.
/// The first reading for a key only sets the baseline: relaunching at 3:20 doesn't celebrate hour 3 again.
public struct HourMarks {
    private var reached: [String: Int] = [:]

    public init() {}

    /// Returns the hour count to celebrate when `seconds` has just crossed a new full hour for `key`.
    public mutating func check(key: String, seconds: TimeInterval) -> Int? {
        let hours = Int(seconds / 3600)
        guard let previous = reached[key] else {
            reached[key] = hours
            return nil
        }
        guard hours > previous else { return nil }
        reached[key] = hours
        return hours >= 1 ? hours : nil
    }
}
