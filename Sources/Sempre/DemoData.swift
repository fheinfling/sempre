#if DEBUG
import Foundation
import SempreCore

/// Made-up data for the screenshots (`Sempre --snapshot <dir>`, see `DevCommands`), which the `screenshots` workflow
/// renders on a runner for the README. Nothing in the app uses it, and it's only compiled into debug builds, so the
/// released app doesn't contain it. It's made up so the README never shows anyone's real projects or agent sessions.
enum DemoData {
    /// Four projects with five weeks of entries, and a timer running for 1:12.
    @MainActor
    static func seed(_ store: Store) {
        let cal = Calendar.current
        for (n, name) in ["Background App", "Client Website", "Admin", "Research"].enumerated() {
            guard let p = store.addProject(name) else { continue }
            for d in 0..<35 where (d + n) % 3 != 0 {
                let day = cal.date(byAdding: .day, value: -d, to: cal.startOfDay(for: Date()))!
                let start = day.addingTimeInterval(TimeInterval(8 + n * 2) * 3600)
                store.addEntry(projectID: p.id, subprojectID: nil, start: start, end: start.addingTimeInterval(TimeInterval(1800 + (d * 977 + n * 1300) % 7200)))
            }
        }
        store.start(store.projects[0])
        // Backdate the running timer so the Track shot shows it mid-session rather than at 0:00:00.
        if let e = store.running { store.updateEntry(e.id, start: Date().addingTimeInterval(-(72 * 60 + 18)), end: nil, subprojectID: nil) }
    }

    /// Claude Code and Codex session logs for the snapshots: last week's work, and two sessions working right now.
    static func agentTranscripts() -> [AgentScanner.Root] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sempre-demo-agents-\(UUID())")
        let cal = Calendar.current, now = Date()
        let lastWeek = cal.dateInterval(of: .weekOfYear, for: cal.date(byAdding: .weekOfYear, value: -1, to: now)!)!.start
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func at(_ day: Int, _ hour: Double) -> Date { lastWeek.addingTimeInterval(Double(day) * 86400 + hour * 3600) }
        func json(_ o: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)! }
        /// Activity every two minutes from each start for its length in minutes; a turn without a length is still running.
        func times(_ turns: [(Date, Double?)]) -> [(start: Date, events: [Date], done: Bool)] {
            turns.map { start, minutes in
                let end = minutes.map { start.addingTimeInterval($0 * 60) } ?? now.addingTimeInterval(-20)
                return (start, Array(stride(from: start, to: end, by: 120)) + [end], minutes != nil)
            }
        }
        func write(_ lines: [String], to url: URL) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        func claude(_ repo: String, _ branch: String, _ title: String, _ turns: [(Date, Double?)]) {
            let id = UUID().uuidString.lowercased(), cwd = "/Users/demo/Work/\(repo)"
            var lines = [json(["type": "ai-title", "aiTitle": title, "sessionId": id])]
            for turn in times(turns) {
                for (i, t) in turn.events.enumerated() {
                    let last = i == turn.events.count - 1
                    let user = i == 0
                    let message: [String: Any] = user ? ["role": "user", "content": title]
                        : ["role": "assistant", "content": [], "stop_reason": last && turn.done ? "end_turn" : "tool_use"]
                    lines.append(json(["type": user ? "user" : "assistant", "message": message, "timestamp": iso.string(from: t),
                                       "cwd": cwd, "gitBranch": branch, "sessionId": id]))
                }
            }
            write(lines, to: root.appendingPathComponent("claude/-Users-demo-Work-\(repo)/\(id).jsonl"))
        }
        func codex(_ repo: String, _ branch: String, _ prompt: String, _ turns: [(Date, Double?)]) {
            let id = UUID().uuidString.lowercased()
            let meta: [String: Any] = ["id": id, "cwd": "/Users/demo/Work/\(repo)",
                                       "git": ["branch": branch, "repository_url": "https://github.com/demo/\(repo).git"]]
            var lines = [json(["timestamp": iso.string(from: turns[0].0), "type": "session_meta", "payload": meta])]
            for turn in times(turns) {
                lines.append(json(["timestamp": iso.string(from: turn.start), "type": "response_item",
                                   "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": prompt]]]]))
                for t in turn.events.dropFirst() {
                    lines.append(json(["timestamp": iso.string(from: t), "type": "response_item", "payload": ["type": "reasoning"]]))
                }
                if turn.done, let end = turn.events.last {
                    lines.append(json(["timestamp": iso.string(from: end), "type": "event_msg", "payload": ["type": "task_complete"]]))
                }
            }
            write(lines, to: root.appendingPathComponent("codex/2026/01/01/rollout-\(id).jsonl"))
        }
        claude("client-website", "main", "Fix the flaky checkout test", [(at(0, 9.5), 42), (at(0, 11), 28)])
        claude("client-website", "dark-mode", "Add dark mode to the settings page", [(at(1, 10), 75), (at(2, 14), 50)])
        codex("client-website", "webhooks", "Review the payment webhook changes", [(at(2, 16), 25)])
        claude("background-app", "swift-6", "Migrate the build to Swift 6", [(at(1, 13), 95), (at(3, 9), 110)])
        codex("background-app", "sync-tests", "Make the sync tests pass", [(at(3, 15), 48), (at(4, 10), 27)])
        claude("docs", "main", "Rewrite the getting started guide", [(at(4, 14), 45)])
        codex("api", "rate-limits", "Add rate limiting to the public API", [(at(2, 9), 62), (at(4, 11.5), 38)])
        claude("background-app", "csv-export", "Add CSV export to the stats view", [(now.addingTimeInterval(-23 * 60 - 14), nil)])
        codex("api", "search", "Speed up the search index", [(now.addingTimeInterval(-8 * 60 - 41), nil)])
        return [.init(kind: .claude, url: root.appendingPathComponent("claude")), .init(kind: .codex, url: root.appendingPathComponent("codex"))]
    }
}
#endif
