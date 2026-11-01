import SwiftUI
import SempreCore

/// Developer flags, handled before the app starts:
/// - `Sempre --snapshot <dir> [--real]`: render the UI to PNGs (demo data, or the real data read-only)
/// - `Sempre --update-check <Sempre.app>`: fetch the latest release, download it and run every check the updater
///   runs, against the signature of the given (Developer ID signed) app. Installs nothing.
/// - `Sempre --agents [days]`: list the Claude Code and Codex sessions agent tracking would find (default: 7 days)
enum DevCommands {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--update-check"), i + 1 < args.count {
            updateCheck(against: URL(fileURLWithPath: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--agents") {
            listAgents(days: args.dropFirst(i + 1).first.flatMap(Double.init) ?? 7)
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        // With --real, render the user's actual data (read-only); otherwise seed demo data.
        let real = args.contains("--real")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sempre-demo-\(UUID()).json")
        let store = real ? Store() : Store(fileURL: file)
        let names = ["Background App", "Client Website", "Admin", "Research"]
        let cal = Calendar.current
        if !real {
            for (n, name) in names.enumerated() {
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

        var shots: [(String, AnyView)] = [Tab.track, .stats].map { ($0.rawValue, AnyView(ContentView(initialTab: $0))) }
        shots.append(("Month", AnyView(StatsView(period: .month).frame(width: 320))))
        let top = store.projects.first?.id
        shots.append(("ProjectYear", AnyView(StatsView(period: .year, projectID: top).frame(width: 320))))
        shots.append(("All", AnyView(StatsView(period: .all).frame(width: 320))))
        // Agent work from the real transcripts (read-only: no record is kept), or from demo ones.
        let defaults = UserDefaults(suiteName: "sempre-snapshot-\(UUID())")!
        defaults.set(true, forKey: AgentTracker.enabledKey)
        let agents = AgentTracker(scanner: real ? AgentScanner() : AgentScanner(roots: demoTranscripts()), defaults: defaults)
        let deadline = Date().addingTimeInterval(120)
        while !agents.loaded && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        // Last week: the same picture whatever day this runs on.
        shots.append(("Agents", AnyView(AgentsView(period: .week, offset: -1).frame(width: 320))))
        let updater = Updater(automatic: false)
        for (name, shot) in shots {
            let view = shot.environmentObject(store).environmentObject(updater).environmentObject(agents)
                .background(Color(nsColor: .windowBackgroundColor))
            for (suffix, look) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                try? windowImage(view, appearance: look)?.write(to: out.appendingPathComponent("\(name)\(suffix).png"))
            }
        }
        // One still frame of each hour chime over a dusk backdrop.
        let frames: [(ChimeStyle, Double)] = [(.brassDust, 1.6), (.pendulum, 1.7), (.firefly, 3.35), (.lightLeak, 1.3)]
        for (style, t) in frames { for (bgName, bg) in [("white", AnyShapeStyle(Color(white: 0.96))), ("dusk", AnyShapeStyle(LinearGradient(colors: [Color(red: 0.17, green: 0.14, blue: 0.25), Color(red: 0.66, green: 0.38, blue: 0.42)], startPoint: .top, endPoint: .bottom)))] {
            let chime = style.make(size: CGSize(width: 900, height: 560))
            let r = ImageRenderer(content: Canvas { ctx, _ in var ctx = ctx; chime.draw(&ctx, t) }
                .frame(width: 900, height: 560)
                .background(bg))
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: out.appendingPathComponent("Chime-\(style.rawValue)-\(bgName).png"))
            }
        } }
        writeIconFrames(to: out)
        exit(0)
    }

    /// Claude Code and Codex session logs for the snapshots: last week's work, and two sessions working right now.
    private static func demoTranscripts() -> [AgentScanner.Root] {
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

    @MainActor
    private static func updateCheck(against reference: URL) -> Never {
        Task { @MainActor in
            do {
                guard let requirement = Updates.requirement(of: reference) else {
                    throw Updates.UpdateError(message: "\(reference.path) isn't signed by a Developer ID team.")
                }
                let updater = Updater(automatic: false)
                let latest = try await updater.fetchLatest()
                print("latest release: \(latest.version), \(latest.download?.absoluteString ?? "no Sempre zip attached")")
                guard let url = latest.download else { exit(1) }
                let app = try await updater.downloadAndVerify(latest, from: url, satisfying: requirement, nextTo: reference, newerThan: "0")
                print("downloaded, notarized, signed like the reference and runs here: Sempre \(latest.version)")
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }

    private static func listAgents(days: Double) -> Never {
        let scanner = AgentScanner()
        print("reading", scanner.roots.map(\.url.path).joined(separator: ", "))
        let clock = Date()
        let now = Date(), range = DateInterval(start: now.addingTimeInterval(-days * 86400), end: now)
        let sessions = scanner.scan(since: range.start, now: now)
        print("\(sessions.count) sessions in \(String(format: "%.1f", Date().timeIntervalSince(clock))) s")
        for s in sessions where s.time(in: range) > 0 {
            print([s.working ? "●" : " ", s.kind.rawValue, Fmt.short(s.time(in: range)), s.project, s.title].joined(separator: "  "))
        }
        exit(0)
    }

    /// Renders a view through an offscreen window rather than ImageRenderer, so AppKit-backed controls (menus) draw too.
    @MainActor
    private static func windowImage(_ view: some View, appearance: NSAppearance.Name) -> Data? {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.setFrameSize(host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)) // let Charts finish drawing
        // A fixed 2× bitmap rather than the screen's scale, so CI runners (1× displays) render sharp shots too.
        let size = host.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Menu bar icon at a few pendulum angles, 4× scale, stacked vertically.
    @MainActor
    private static func writeIconFrames(to out: URL) {
        let frames: [(CGFloat, String?, Bool)] = [(0, nil, false), (-24, "Client 1:05", false), (0, "Client 1:05", true), (24, "Client · break?", false)]
        let images = frames.map { MenuBarIcon.image(angle: $0.0, text: $0.1, dimColon: $0.2) }
        let scale: CGFloat = 4
        let w = (images.map(\.size.width).max() ?? 16) * scale + 32
        let h = CGFloat(images.count) * 26 * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        for (i, img) in images.enumerated() {
            let y = h - CGFloat(i + 1) * 26 * scale + 16
            img.draw(in: NSRect(x: 16, y: y, width: img.size.width * scale, height: img.size.height * scale))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("Icon.png"))
    }
}
