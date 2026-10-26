import SwiftUI
import SempreCore

/// Developer flags, handled before the app starts:
/// - `Sempre --import-test <path>`: dry-run the Tyme importer and print a summary
/// - `Sempre --snapshot <dir> [--real]`: render the UI to PNGs (demo data, or the real data read-only)
enum DevCommands {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--import-test"), i + 1 < args.count {
            do {
                let r = try TymeImporter.importFrom(URL(fileURLWithPath: args[i + 1]))
                let names = Dictionary(uniqueKeysWithValues: r.projects.map { ($0.id, $0.name) })
                var totals: [UUID: TimeInterval] = [:]
                for e in r.entries { totals[e.projectID, default: 0] += e.end!.timeIntervalSince(e.start) }
                print("projects: \(r.projects.count) (archived \(r.projects.filter(\.archived).count)), entries: \(r.entries.count)")
                for (id, t) in totals.sorted(by: { $0.value > $1.value }) { print(String(format: "%8.1fh  %@", t / 3600, names[id] ?? "?")) }
            } catch { print("error: \(error.localizedDescription)") }
            exit(0)
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        // With --real, render the user's actual data (read-only); otherwise seed demo data.
        let real = args.contains("--real")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sempre-demo-\(UUID()).json")
        let store = real ? Store() : Store(fileURL: file)
        let names = ["Background App", "Client Website", "Admin", "Research"]
        let cal = Calendar.current
        var projects: [Project] = []
        var entries: [Entry] = []
        for (n, name) in names.enumerated() {
            let p = Project(name: name, color: n, tymeID: name)
            projects.append(p)
            for d in 0..<35 where (d + n) % 3 != 0 {
                let day = cal.date(byAdding: .day, value: -d, to: cal.startOfDay(for: Date()))!
                let start = day.addingTimeInterval(TimeInterval(8 + n * 2) * 3600)
                entries.append(Entry(projectID: p.id, start: start, end: start.addingTimeInterval(TimeInterval(1800 + (d * 977 + n * 1300) % 7200)), tymeID: "\(n)-\(d)"))
            }
        }
        if !real {
            _ = store.merge(projects: projects, entries: entries)
            store.start(store.projects[0])
            // Backdate the running timer so the Track shot shows it mid-session rather than at 0:00:00.
            if let e = store.running { store.updateEntry(e.id, start: Date().addingTimeInterval(-(72 * 60 + 18)), end: nil, subprojectID: nil) }
        }

        var shots: [(String, AnyView)] = Tab.allCases.map { ($0.rawValue, AnyView(ContentView(initialTab: $0))) }
        shots.append(("Month", AnyView(StatsView(period: .month).frame(width: 320))))
        let top = store.projects.first?.id
        shots.append(("ProjectYear", AnyView(StatsView(period: .year, projectID: top).frame(width: 320))))
        shots.append(("All", AnyView(StatsView(period: .all).frame(width: 320))))
        for (name, shot) in shots {
            let view = shot.environmentObject(store).background(Color(nsColor: .windowBackgroundColor))
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
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
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
