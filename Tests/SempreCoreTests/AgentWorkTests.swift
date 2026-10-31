import Foundation
import Testing
@testable import SempreCore

@Suite("Agent work from Claude Code and Codex transcripts")
struct AgentWorkTests {
    let t0 = Date(timeIntervalSince1970: 1_793_440_000) // 2026-10-31T10:26:40Z

    func iso(_ minutes: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: t0.addingTimeInterval(minutes * 60))
    }

    func claude(_ type: String, _ minutes: Double, stop: String? = nil, text: String? = nil, extra: String = "") -> String {
        let content = text.map { "\"content\":\(json($0))" } ?? "\"content\":[{\"type\":\"tool_use\",\"input\":{\"timestamp\":\"x\"}}]"
        let stop = stop.map { ",\"stop_reason\":\"\($0)\"" } ?? ""
        return "{\"isSidechain\":false,\"message\":{\"role\":\"\(type)\",\(content)\(stop)},\"type\":\"\(type)\",\"timestamp\":\"\(iso(minutes))\",\"cwd\":\"/tmp/proj\"\(extra)}"
    }

    func json(_ s: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed), encoding: .utf8)!
    }

    func read(_ kind: AgentKind, _ lines: [String], id: String = "s") -> AgentLog {
        var log = AgentLog(kind: kind, sessionID: id)
        log.read(Data((lines.joined(separator: "\n") + "\n").utf8))
        return log
    }

    // MARK: Spans

    @Test func aTurnRunsFromPromptToTheAgentsLastMessage() {
        let log = read(.claude, [
            claude("user", 0, text: "Fix the build"),
            claude("assistant", 1, stop: "tool_use"),
            claude("user", 4),
            claude("assistant", 5, stop: "end_turn"),
            // The human takes 20 minutes to reply: not agent time.
            claude("user", 25, text: "Thanks, now the tests"),
            claude("assistant", 27, stop: "end_turn"),
        ])
        #expect(log.spans(now: t0.addingTimeInterval(3600)).map(\.duration) == [5 * 60, 2 * 60])
        #expect(log.prompt == "Fix the build")
        #expect(log.cwd == "/tmp/proj")
        #expect(!log.isWorking(now: t0.addingTimeInterval(28 * 60)))
    }

    @Test func aLongSilenceEndsTheSpan() {
        var log = AgentLog(kind: .claude, sessionID: "s")
        log.add(t0)
        log.add(t0.addingTimeInterval(9 * 60))   // a long tool run still counts
        log.add(t0.addingTimeInterval(30 * 60))  // waited on a question for 21 minutes: a new span
        log.add(t0.addingTimeInterval(31 * 60), endsTurn: true)
        #expect(log.spans(now: t0.addingTimeInterval(3600)).map(\.duration) == [9 * 60, 60])
    }

    @Test func anOpenTurnRunsUntilNowWhileTheAgentIsActive() {
        var log = AgentLog(kind: .codex, sessionID: "s")
        log.add(t0)
        log.add(t0.addingTimeInterval(120))
        let soon = t0.addingTimeInterval(300)
        #expect(log.isWorking(now: soon))
        #expect(log.spans(now: soon).map(\.duration) == [300])
        // Silent past the idle gap: it stopped (crashed, or is waiting) at its last activity.
        let later = t0.addingTimeInterval(3600)
        #expect(!log.isWorking(now: later))
        #expect(log.spans(now: later).map(\.duration) == [120])
    }

    // MARK: Claude Code

    @Test func claudeBookkeepingIsNotActivity() {
        let log = read(.claude, [
            claude("user", 0, text: "<command-name>/model</command-name>"),
            claude("user", 0.1, text: "caveat", extra: ",\"isMeta\":true"),
            "{\"type\":\"ai-title\",\"aiTitle\":\"Agent work tracker\",\"sessionId\":\"s\"}",
            "{\"type\":\"mode\",\"mode\":\"auto\"}",
        ])
        #expect(log.spans(now: t0.addingTimeInterval(60)).isEmpty)
        #expect(!log.isWorking(now: t0.addingTimeInterval(60)))
        #expect(log.title == "Agent work tracker")
        #expect(log.prompt == nil)
    }

    @Test func claudeInterruptEndsTheTurn() {
        let log = read(.claude, [
            claude("user", 0, text: "Refactor everything"),
            claude("assistant", 2, stop: "tool_use"),
            claude("user", 3, text: "[Request interrupted by user]"),
        ])
        #expect(!log.isWorking(now: t0.addingTimeInterval(4 * 60)))
        #expect(log.spans(now: t0.addingTimeInterval(4 * 60)).map(\.duration) == [3 * 60])
    }

    @Test func claudePromptSkipsRemindersAndFlattensWhitespace() {
        let log = read(.claude, [
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"<system-reminder>x</system-reminder>\"},{\"type\":\"text\",\"text\":\"add an\\n\\nagent \\\"tracker\\\"\"}]},\"timestamp\":\"\(iso(0))\"}",
        ])
        #expect(log.prompt == "add an agent \"tracker\"")
    }

    @Test func linesAreReadIncrementallyAndAHalfWrittenLineWaits() {
        var log = AgentLog(kind: .claude, sessionID: "s")
        let first = claude("user", 0, text: "Go") + "\n"
        let second = claude("assistant", 3, stop: "end_turn")
        var data = Data((first + second.prefix(40)).utf8)
        log.read(data)
        #expect(log.isWorking(now: t0.addingTimeInterval(60)))
        data = Data((first + second + "\n").utf8)
        log.read(data)
        #expect(log.spans(now: t0.addingTimeInterval(600)).map(\.duration) == [3 * 60])
        #expect(!log.isWorking(now: t0.addingTimeInterval(600)))
    }

    // MARK: Codex

    func codex(_ minutes: Double, _ type: String, _ payload: String) -> String {
        "{\"timestamp\":\"\(iso(minutes))\",\"ordinal\":0,\"type\":\"\(type)\",\"payload\":\(payload)}"
    }

    @Test func codexSessionMetaTurnsAndPrompt() {
        let log = read(.codex, [
            codex(0, "session_meta", "{\"id\":\"abc\",\"cwd\":\"/w/repo-wt/fix\",\"source\":\"exec\",\"git\":{\"branch\":\"fix\",\"repository_url\":\"https://github.com/me/repo.git\"}}"),
            codex(0, "event_msg", "{\"type\":\"task_started\"}"),
            codex(0, "response_item", "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"# AGENTS.md instructions for /w\"}]}"),
            codex(0, "response_item", "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"<environment_context>\"}]}"),
            codex(0, "response_item", "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Make the tests pass\"}]}"),
            codex(6, "response_item", "{\"type\":\"reasoning\",\"encrypted_content\":\"{]\\\"}\"}"),
            codex(12, "event_msg", "{\"type\":\"task_complete\",\"duration_ms\":720000}"),
        ], id: "rollout-file-name")
        #expect(log.sessionID == "abc")
        #expect(log.cwd == "/w/repo-wt/fix")
        #expect(log.repository == "repo")
        #expect(log.prompt == "Make the tests pass")
        #expect(log.spans(now: t0.addingTimeInterval(3600)).map(\.duration) == [12 * 60])
        #expect(!log.isSubagent)
    }

    @Test func codexSubagentBelongsToItsParent() {
        let log = read(.codex, [
            codex(0, "session_meta", "{\"id\":\"child\",\"parent_thread_id\":\"parent\",\"cwd\":\"/w\",\"source\":{\"subagent\":\"review\"}}"),
        ])
        #expect(log.sessionID == "parent")
        #expect(log.isSubagent)
    }

    // MARK: Scanner

    @Test func scannerMergesSubagentsAndReadsOnlyWhatsNew() throws {
        let root = tempDir()
        let folder = root.appendingPathComponent("-tmp-proj")
        let subagents = folder.appendingPathComponent("sess/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let main = folder.appendingPathComponent("sess.jsonl")
        try (claude("user", 0, text: "Plan it") + "\n" + claude("assistant", 2, stop: "end_turn") + "\n").write(to: main, atomically: true, encoding: .utf8)
        // A background subagent working on after the main turn ended, overlapping it by a minute.
        try (claude("user", 1, text: "Research") + "\n" + claude("assistant", 6, stop: "end_turn") + "\n")
            .write(to: subagents.appendingPathComponent("agent-a.jsonl"), atomically: true, encoding: .utf8)

        let scanner = AgentScanner(roots: [.init(kind: .claude, url: root)])
        let now = t0.addingTimeInterval(3600)
        var sessions = scanner.scan(since: .distantPast, now: now)
        #expect(sessions.count == 1)
        #expect(sessions[0].id == "claude:sess")
        #expect(sessions[0].title == "Plan it")
        #expect(sessions[0].spans.map(\.duration) == [6 * 60])

        let h = try FileHandle(forWritingTo: main)
        try h.seekToEnd()
        try h.write(contentsOf: Data((claude("user", 20, text: "More") + "\n" + claude("assistant", 22, stop: "end_turn") + "\n").utf8))
        try h.close()
        sessions = scanner.scan(since: .distantPast, now: now)
        #expect(sessions[0].spans.map(\.duration) == [6 * 60, 2 * 60])
        #expect(sessions[0].time(in: DateInterval(start: t0.addingTimeInterval(21 * 60), end: now)) == 60)
    }

    @Test func scannerSkipsFilesUntouchedSinceTheHorizon() throws {
        let root = tempDir()
        let folder = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("old.jsonl")
        try (claude("user", 0, text: "Hi") + "\n" + claude("assistant", 1, stop: "end_turn") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: file.path)
        let scanner = AgentScanner(roots: [.init(kind: .claude, url: root)])
        #expect(scanner.scan(since: t0.addingTimeInterval(86_400)).isEmpty)
        #expect(scanner.scan(since: t0.addingTimeInterval(-86_400)).count == 1)
    }

    @Test func repositoryOfAWorktreeIsItsMainRepository() throws {
        let root = tempDir()
        let repo = root.appendingPathComponent("sempre")
        let sub = repo.appendingPathComponent("Sources/Core")
        let wt = root.appendingPathComponent("elsewhere/feature-x")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git/worktrees/feature-x\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(AgentScanner.repository(of: sub) == "sempre")
        #expect(AgentScanner.repository(of: wt) == "sempre")
        #expect(AgentScanner.repository(of: repo.appendingPathComponent(".claude/worktrees/gone")) == "sempre")
        #expect(AgentScanner.repository(of: root.appendingPathComponent("loose")) == "loose")
    }

    @Test func mergeJoinsOverlappingSpans() {
        let a = DateInterval(start: t0, duration: 600)
        let b = DateInterval(start: t0.addingTimeInterval(300), duration: 600)
        let c = DateInterval(start: t0.addingTimeInterval(2000), duration: 60)
        #expect(AgentScanner.merge([c, b, a]) == [DateInterval(start: t0, duration: 900), c])
    }

    // MARK: Archive

    func session(_ id: String, _ spans: [(Double, Double)], working: Bool = false) -> AgentSession {
        AgentSession(id: id, kind: .claude, cwd: "/w/repo", project: "repo", branch: "main", title: id,
                     spans: spans.map { DateInterval(start: t0.addingTimeInterval($0.0 * 60), end: t0.addingTimeInterval($0.1 * 60)) },
                     working: working)
    }

    @Test func archiveKeepsSessionsAfterTheirTranscriptsAreGone() {
        let folder = tempDir()
        var archive = AgentArchive(folder: folder, machineID: "mac-a")
        #expect(archive.isNew)
        _ = archive.update(with: [session("a", [(0, 10)]), session("b", [(20, 30)])], horizon: .distantPast, now: t0)
        #expect(!archive.isNew)

        // Relaunched a month later: "a" was cleaned up by the agent, "b" goes on with new work after the horizon.
        archive = AgentArchive(folder: folder, machineID: "mac-a")
        #expect(!archive.isNew)
        let horizon = t0.addingTimeInterval(3600)
        let all = archive.update(with: [session("b", [(20, 30), (70, 80)])], horizon: horizon, now: t0.addingTimeInterval(7200))
        #expect(Set(all.map(\.id)) == ["a", "b"])
        #expect(all.first { $0.id == "b" }?.spans.count == 2)
        #expect(all.first { $0.id == "a" }?.branch == "main")
    }

    @Test func archiveSavesARunningSpanOnlyOnceItsDone() {
        let folder = tempDir()
        let archive = AgentArchive(folder: folder, machineID: "mac-a")
        let live = archive.update(with: [session("a", [(0, 10), (20, 25)], working: true)], horizon: .distantPast, now: t0)
        #expect(live[0].working)
        #expect(live[0].spans.count == 2)
        let saved = AgentArchive(folder: folder, machineID: "mac-a").update(with: [], horizon: .distantFuture, now: t0)
        #expect(saved.map { $0.spans.count } == [1])
        #expect(saved[0].working == false)
    }

    @Test func archiveReadsTheOtherMacsSessions() {
        let folder = tempDir()
        let other = AgentArchive(folder: folder, machineID: "mac-b")
        _ = other.update(with: [session("b", [(0, 10)])], horizon: .distantPast, now: t0)
        let mine = AgentArchive(folder: folder, machineID: "mac-a")
        let all = mine.update(with: [session("a", [(30, 40)])], horizon: .distantPast, now: t0)
        #expect(all.map(\.id) == ["a", "b"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mac-a.json").path))
    }

    @Test func branchComesFromTheLatestActivity() {
        let claudeLog = read(.claude, [
            claude("user", 0, text: "Go", extra: ",\"gitBranch\":\"main\""),
            claude("assistant", 1, stop: "end_turn", extra: ",\"gitBranch\":\"feature-x\""),
            claude("user", 2, text: "More", extra: ",\"gitBranch\":\"HEAD\""),
        ])
        #expect(claudeLog.branch == "feature-x")
        let codexLog = read(.codex, [
            codex(0, "session_meta", "{\"id\":\"abc\",\"git\":{\"branch\":\"fix/tests\"}}"),
        ])
        #expect(codexLog.branch == "fix/tests")
    }

    // MARK: JSON skimming

    @Test func skimFindsTopLevelValuesOnly() {
        let line = #"{"message":{"type":"user","timestamp":"2000-01-01T00:00:00Z","s":"a\"}{["},"n":-1.5e3,"ok":true,"timestamp":"2026-10-31T12:32:45.248Z","type":"assistant"}"#
        let data = Data(line.utf8)
        data.withUnsafeBytes { buf in
            let j = JSONSkim(buf)
            let f = j.fields(0..<buf.count, JSONSkim.keys("type", "timestamp", "ok", "missing"))
            #expect(f[0].flatMap(j.string) == "assistant")
            #expect(abs(f[1].flatMap(j.date)!.timeIntervalSince1970 - 1_793_449_965.248) < 0.001)
            #expect(f[2].map(j.isTrue) == true)
            #expect(f[3] == nil)
        }
    }

    @Test func skimDatesMatchTheFormatter() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for s in ["2024-02-29T23:59:59.999Z", "2026-01-01T00:00:00.000Z", "1999-12-31T12:00:00.5Z"] {
            let data = Data("\"\(s)\"".utf8)
            let parsed = data.withUnsafeBytes { JSONSkim($0).date(0..<$0.count) }
            #expect(abs(parsed!.timeIntervalSince(f.date(from: s)!)) < 0.001, "\(s)")
        }
    }
}
