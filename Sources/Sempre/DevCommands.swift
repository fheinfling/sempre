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
        // Agent work only from real transcripts: there's no demo data for it.
        let defaults = UserDefaults(suiteName: "sempre-snapshot-\(UUID())")!
        defaults.set(real, forKey: AgentTracker.enabledKey)
        let agents = AgentTracker(defaults: defaults)
        if real {
            let deadline = Date().addingTimeInterval(120)
            while !agents.loaded && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            shots.append(("Agents", AnyView(AgentsView().frame(width: 320))))
            shots.append(("AgentsWeek", AnyView(AgentsView(period: .week).frame(width: 320))))
            shots.append(("AgentsYear", AnyView(AgentsView(period: .year).frame(width: 320))))
        }
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
