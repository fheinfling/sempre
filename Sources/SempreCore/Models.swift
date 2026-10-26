import Foundation

public struct Project: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// Palette index, used when `rgb` is nil.
    public var color: Int
    public var archived: Bool
    public var tymeID: String?
    /// Exact 0xRRGGBB colour (from Tyme); overrides the palette index when set.
    public var rgb: Int?

    public init(id: UUID = UUID(), name: String, color: Int, archived: Bool = false, tymeID: String? = nil, rgb: Int? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.archived = archived
        self.tymeID = tymeID
        self.rgb = rgb
    }
}

/// Optional second level under a project (Tyme calls these tasks).
public struct Subproject: Codable, Identifiable, Hashable {
    public var id: UUID
    public var projectID: UUID
    public var name: String
    public var archived: Bool
    public var tymeID: String?

    public init(id: UUID = UUID(), projectID: UUID, name: String, archived: Bool = false, tymeID: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.archived = archived
        self.tymeID = tymeID
    }
}

public struct Entry: Codable, Identifiable, Hashable {
    public var id: UUID
    public var projectID: UUID
    public var subprojectID: UUID?
    public var start: Date
    /// nil while the timer is running.
    public var end: Date?
    public var tymeID: String?
    public var breaks: [Break]?

    public init(id: UUID = UUID(), projectID: UUID, subprojectID: UUID? = nil, start: Date, end: Date? = nil,
                tymeID: String? = nil, breaks: [Break]? = nil) {
        self.id = id
        self.projectID = projectID
        self.subprojectID = subprojectID
        self.start = start
        self.end = end
        self.tymeID = tymeID
        self.breaks = breaks
    }

    /// Raw overlap with the interval, breaks ignored.
    public func span(in interval: DateInterval, now: Date) -> TimeInterval {
        let s = max(start, interval.start)
        let e = min(end ?? now, interval.end)
        return max(0, e.timeIntervalSince(s))
    }

    /// Worked time inside the interval: overlap minus breaks.
    /// Timed breaks subtract their own overlap; duration-only breaks are spread evenly over the entry.
    public func duration(in interval: DateInterval, now: Date) -> TimeInterval {
        let raw = span(in: interval, now: now)
        guard raw > 0, let breaks, !breaks.isEmpty else { return raw }
        let entryEnd = end ?? now
        let full = entryEnd.timeIntervalSince(start)
        var off: TimeInterval = 0
        for b in breaks {
            if let bs = b.start {
                let s = max(bs, interval.start, start)
                let e = min(bs.addingTimeInterval(b.duration), interval.end, entryEnd)
                off += max(0, e.timeIntervalSince(s))
            } else if full > 0 {
                off += min(b.duration, full) * raw / full
            }
        }
        return max(0, raw - off)
    }

    /// Worked time of the whole entry so far.
    public func worked(now: Date) -> TimeInterval {
        duration(in: DateInterval(start: start, end: max(start, end ?? now)), now: now)
    }

    public var breakTotal: TimeInterval { breaks?.reduce(0) { $0 + $1.duration } ?? 0 }
}

/// A pause inside an entry: either just a length, or a length at an exact time.
public struct Break: Codable, Identifiable, Hashable {
    public var id: UUID
    public var start: Date?
    public var duration: TimeInterval

    public init(id: UUID = UUID(), start: Date? = nil, duration: TimeInterval) {
        self.id = id
        self.start = start
        self.duration = duration
    }
}

/// Everything Sempre stores, as written to `sempre.json`.
public struct Library: Codable {
    public var projects: [Project] = []
    public var subprojects: [Subproject] = []
    public var entries: [Entry] = []

    public init() {}

    // Files written before subprojects existed have no "subprojects" key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decode([Project].self, forKey: .projects)
        subprojects = try c.decodeIfPresent([Subproject].self, forKey: .subprojects) ?? []
        entries = try c.decode([Entry].self, forKey: .entries)
    }
}
