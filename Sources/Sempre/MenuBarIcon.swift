import AppKit
import Combine
import SwiftUI
import SempreCore

/// Drives the menu bar animation. Ticks ~15×/s only while a timer runs, so idle costs nothing.
@MainActor
final class MenuTicker: ObservableObject {
    @Published private(set) var phase: TimeInterval = 0
    private var timer: Timer?
    private var sub: AnyCancellable?

    init(store: Store) {
        sub = store.$library
            .map { $0.entries.contains { $0.end == nil } }
            .removeDuplicates()
            .sink { [weak self] running in self?.setRunning(running) }
    }

    nonisolated static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func setRunning(_ running: Bool) {
        timer?.invalidate()
        timer = nil
        phase = Date().timeIntervalSinceReferenceDate
        guard running else { return }
        let t = Timer(timeInterval: Self.reduceMotion ? 1 : 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.phase = Date().timeIntervalSinceReferenceDate }
        }
        // .common keeps it ticking while menus are open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

/// Renders the status item: a metronome glyph plus optional text, as one template image.
enum MenuBarIcon {
    /// Pendulum angle for a time: swings ±24°, passing the centre once per second.
    static func angle(at phase: TimeInterval) -> CGFloat {
        MenuTicker.reduceMotion ? 0 : 24 * sin(.pi * phase)
    }

    static func image(angle: CGFloat, text: String?, dimColon: Bool) -> NSImage {
        let height: CGFloat = 18
        let iconWidth: CGFloat = 16
        let attributed = text.map { attributedText($0, dimColon: dimColon) }
        let textWidth = attributed.map { ceil($0.size().width) } ?? 0
        let size = NSSize(width: iconWidth + (attributed == nil ? 0 : 5 + textWidth), height: height)

        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: 1)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.3)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)

            // Body: a trapezoid, open at the top like a real metronome.
            ctx.move(to: CGPoint(x: 5.6, y: 1.5))
            ctx.addLine(to: CGPoint(x: 10.4, y: 1.5))
            ctx.addLine(to: CGPoint(x: 13.4, y: 14.5))
            ctx.addLine(to: CGPoint(x: 2.6, y: 14.5))
            ctx.closePath()
            ctx.strokePath()

            // Pendulum, pivoting near the base.
            ctx.translateBy(x: 8, y: 12.6)
            ctx.rotate(by: angle * .pi / 180)
            ctx.move(to: .zero)
            ctx.addLine(to: CGPoint(x: 0, y: -9.6))
            ctx.strokePath()
            ctx.fill(CGRect(x: -1.5, y: -7.4, width: 3, height: 2.1))
            ctx.restoreGState()

            if let attributed {
                let y = (height - attributed.size().height) / 2
                attributed.draw(at: NSPoint(x: iconWidth + 5, y: y))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func attributedText(_ text: String, dimColon: Bool) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        // Dim the last colon (the h:mm one) on alternate seconds.
        if dimColon, let r = text.range(of: ":", options: .backwards) {
            s.addAttribute(.foregroundColor, value: NSColor.black.withAlphaComponent(0.25), range: NSRange(r, in: text))
        }
        return s
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: Store
    @ObservedObject var ticker: MenuTicker
    @AppStorage("showProjectName") private var showProjectName = true
    @AppStorage("menuBarTime") private var menuBarTime = MenuBarTime.timer

    var body: some View {
        let now = Date()
        if let entry = store.running {
            let today = Calendar.current.dateInterval(of: .day, for: now)!
            let text = MenuBarText.label(
                project: showProjectName ? store.project(entry.projectID)?.name : nil,
                worked: entry.worked(now: now),
                shown: menuBarTime == .projectToday ? store.total(for: entry.projectID, in: today) : nil,
                today: store.total(in: today),
                hadBreak: !(entry.breaks ?? []).isEmpty
            )
            let blink = !MenuTicker.reduceMotion && Int(now.timeIntervalSinceReferenceDate) % 2 == 1
            Image(nsImage: MenuBarIcon.image(angle: MenuBarIcon.angle(at: ticker.phase), text: text, dimColon: blink))
        } else {
            Image(nsImage: MenuBarIcon.image(angle: 0, text: nil, dimColon: false))
        }
    }
}

/// What the time next to the menu bar icon counts.
enum MenuBarTime: String {
    case timer          // the running entry
    case projectToday   // everything tracked on the running project today
}
