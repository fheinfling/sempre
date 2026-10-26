import AppKit
import Combine
import SempreCore
import SwiftUI

/// Watches the running timer and plays a short chime across the screen at every new full hour.
@MainActor
final class HourChime: ObservableObject {
    private var marks = HourMarks()
    private var sub: AnyCancellable?
    private var panel: NSPanel?

    init(store: Store) {
        sub = store.$now.sink { [weak self, weak store] now in
            guard let self, let store else { return }
            MainActor.assumeIsolated { self.check(store: store, now: now) }
        }
    }

    static var style: ChimeStyle { ChimeStyle(rawValue: UserDefaults.standard.string(forKey: "chimeStyle") ?? "") ?? .brassDust }

    private func check(store: Store, now: Date) {
        guard let entry = store.running else { return }
        let projectToday = UserDefaults.standard.string(forKey: "menuBarTime") == MenuBarTime.projectToday.rawValue
        let today = Calendar.current.dateInterval(of: .day, for: now)!
        let seconds = projectToday ? store.total(for: entry.projectID, in: today) : entry.worked(now: now)
        let key = projectToday ? "project-\(entry.projectID)-\(today.start.timeIntervalSince1970)" : "entry-\(entry.id)"
        guard marks.check(key: key, seconds: seconds) != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        show(Self.style)
    }

    /// Plays a chime once over the main screen. Click-through, never takes focus.
    func show(_ style: ChimeStyle) {
        panel?.orderOut(nil)
        guard let screen = NSScreen.main else { return }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let size = screen.frame.size
        let chime = (style == .surprise ? ChimeStyle.effects.randomElement()! : style).make(size: size)
        let duration = chime.duration
        panel.contentView = NSHostingView(rootView: ChimeCanvas { ctx, t in chime.draw(&ctx, t) })
        panel.orderFrontRegardless()
        self.panel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.2) { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.panel === panel { self?.panel = nil }
        }
    }
}

/// A point of light: a warm halo, a white-hot core and, for glints, a thin four-point star.
/// Light colours throughout; the faint gold halo is what lifts it off a white window.
enum Sparkle {
    static let core = Color(red: 1, green: 0.99, blue: 0.95)
    static let ray = Color(red: 0.97, green: 0.77, blue: 0.33)    // warm gold, not brown
    static let halo = Color(red: 0.98, green: 0.78, blue: 0.36)

    static func draw(_ ctx: inout GraphicsContext, at p: CGPoint, size: CGFloat, alpha: Double, glint: Bool, spin: Angle) {
        guard alpha > 0.01, size > 0.2 else { return }
        let h = size * 2.8
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - h, y: p.y - h, width: h * 2, height: h * 2)),
                 with: .radialGradient(Gradient(stops: [.init(color: halo.opacity(alpha * 0.85), location: 0),
                                                        .init(color: halo.opacity(alpha * 0.32), location: 0.3),
                                                        .init(color: halo.opacity(0), location: 1)]),
                                       center: p, startRadius: 0, endRadius: h))
        if glint {
            // Four slim rays, like light catching a facet.
            var star = Path()
            let tip = size * 3.2, waist = size * 0.2
            for i in 0..<8 {
                let a = spin.radians + Double(i) * .pi / 4
                let r = i.isMultiple(of: 2) ? tip : waist
                let pt = CGPoint(x: p.x + CGFloat(cos(a)) * r, y: p.y + CGFloat(sin(a)) * r)
                i == 0 ? star.move(to: pt) : star.addLine(to: pt)
            }
            star.closeSubpath()
            ctx.fill(star, with: .color(ray.opacity(alpha)))
        }
        let c = size * 0.55
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - c, y: p.y - c, width: c * 2, height: c * 2)), with: .color(core.opacity(alpha)))
    }

    /// Flicker between dim and bright.
    static func twinkle(_ t: Double, rate: Double, phase: Double) -> Double { 0.45 + 0.55 * (0.5 + 0.5 * sin(t * rate + phase)) }
}

/// One play of the effect: a breeze and a few hundred specks, all chosen at random.
struct BrassDrift {
    static let duration: TimeInterval = 5.4

    struct Speck {
        var x: CGFloat, y: CGFloat      // start, left of the screen
        var speed: CGFloat              // points per second, rightwards
        var size: CGFloat
        var phase: Double, twinkle: Double
        var alpha: Double
    }

    var size: CGSize
    var wind: CGFloat                   // gentle rise or fall across the screen
    var sway: CGFloat
    var specks: [Speck]

    static func random(in size: CGSize) -> BrassDrift {
        let w = size.width, h = size.height
        let count = Int(min(420, max(180, w * h / 9000)))
        let specks = (0..<count).map { _ in
            Speck(x: .random(in: -w * 0.6 ... -10), y: .random(in: h * 0.08 ... h * 0.95),
                  speed: w * .random(in: 0.27...0.58), size: .random(in: 2.2...7),
                  phase: .random(in: 0...6.28), twinkle: .random(in: 2...6), alpha: .random(in: 0.7...1))
        }
        return BrassDrift(size: size, wind: .random(in: -0.25...0.25), sway: h * .random(in: 0.012...0.03), specks: specks)
    }

    /// Draws the drift at `t` seconds in.
    func draw(_ ctx: inout GraphicsContext, t: Double) {
        // A soft dark shadow keeps the light visible on white windows too.
        ctx.addFilter(.shadow(color: .black.opacity(0.45), radius: 5, x: 0, y: 1))
        let fadeIn = min(1, t * 2)
        let fadeOut = max(0, 1 - max(0, t - 3.1) * 1.1)
        let pale = Brass.pale
        let brass = Brass.mid
        for s in specks {
            let x = s.x + s.speed * CGFloat(t)
            guard x > -10, x < size.width + 10 else { continue }
            let y = s.y + CGFloat(sin(t * 1.6 + s.phase)) * sway + wind * (x - s.x) * 0.25
            let a = s.alpha * fadeIn * fadeOut * (0.6 + 0.4 * sin(t * s.twinkle + s.phase))
            guard a > 0.01 else { continue }
            let big = s.size > 2.4
            if big { // a soft glow around the larger specks
                let r = s.size * 3
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .radialGradient(Gradient(colors: [Brass.light.opacity(a * 0.45), Brass.light.opacity(0)]),
                                               center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
            }
            // Gold specks; the larger ones get a bright centre, like light catching metal.
            ctx.fill(Path(ellipseIn: CGRect(x: x - s.size / 2, y: y - s.size / 2, width: s.size, height: s.size)),
                     with: .color(brass.opacity(a)))
            if big {
                let c = s.size * 0.4
                ctx.fill(Path(ellipseIn: CGRect(x: x - c / 2, y: y - c / 2, width: c, height: c)), with: .color(pale.opacity(a)))
            }
        }
    }
}

enum ChimeStyle: String, CaseIterable {
    case brassDust, pendulum, firefly, lightLeak, surprise

    /// The real effects; Surprise picks one of these each hour.
    static let effects: [ChimeStyle] = [.brassDust, .pendulum, .firefly, .lightLeak]

    var title: String {
        switch self {
        case .brassDust: "Brass Dust"
        case .pendulum: "Pendulum"
        case .firefly: "Firefly"
        case .lightLeak: "Light Leak"
        case .surprise: "Surprise Me"
        }
    }

    /// A freshly randomised play of this effect.
    func make(size: CGSize) -> AnyChime {
        switch self {
        case .pendulum: let c = PendulumSwing.random(in: size); return AnyChime(duration: c.duration, draw: c.draw)
        case .firefly: let c = Firefly.random(in: size); return AnyChime(duration: Firefly.duration, draw: c.draw)
        case .lightLeak: let c = LightLeak.random(in: size); return AnyChime(duration: c.duration, draw: c.draw)
        case .brassDust, .surprise: let c = BrassDrift.random(in: size); return AnyChime(duration: BrassDrift.duration, draw: c.draw)
        }
    }
}

struct AnyChime {
    let duration: TimeInterval
    let draw: (inout GraphicsContext, Double) -> Void
}

enum Brass {
    static let pale = Color(red: 1, green: 0.945, blue: 0.79)
    static let light = Color(red: 0.97, green: 0.80, blue: 0.45)
    static let mid = Color(red: 0.85, green: 0.62, blue: 0.22)

    /// A soft round glow, bright in the middle.
    static func glow(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: CGFloat, alpha: Double) {
        guard alpha > 0.01 else { return }
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(stops: [.init(color: pale.opacity(alpha), location: 0),
                                                        .init(color: light.opacity(alpha * 0.3), location: 0.35),
                                                        .init(color: light.opacity(0), location: 1)]),
                                       center: p, startRadius: 0, endRadius: r))
    }

    static func ease(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
    /// 0 → 1 → 0 envelope: fades in over the first `fadeIn` and out over the last `fadeOut` of the play.
    static func envelope(_ p: Double, fadeIn: Double, fadeOut: Double) -> Double {
        max(0, min(1, p / fadeIn) * min(1, (1 - p) / fadeOut))
    }
}

/// A glowing mote that wanders a random curve from left to right, then bursts into gold sparks.
struct Firefly {
    static let travel: TimeInterval = 3
    static let duration: TimeInterval = travel + 1.8
    var points: [CGPoint]
    var sparks: [Spark]

    static func random(in size: CGSize) -> Firefly {
        let w = size.width, h = size.height
        return Firefly(points: [
            CGPoint(x: -20, y: .random(in: h * 0.3...h * 0.8)),
            CGPoint(x: w * .random(in: 0.2...0.4), y: .random(in: h * 0.1...h * 0.9)),
            CGPoint(x: w * .random(in: 0.55...0.75), y: .random(in: h * 0.1...h * 0.9)),
            CGPoint(x: w * .random(in: 0.68...0.85), y: .random(in: h * 0.3...h * 0.65)),
        ], sparks: Spark.burst(count: 160, speed: 120...620))
    }

    private func at(_ u: Double) -> CGPoint {
        let u = CGFloat(min(1, max(0, u))), v = 1 - u
        let a = v * v * v, b = 3 * v * v * u, c = 3 * v * u * u, d = u * u * u
        return CGPoint(x: a * points[0].x + b * points[1].x + c * points[2].x + d * points[3].x,
                       y: a * points[0].y + b * points[1].y + c * points[2].y + d * points[3].y)
    }

    func draw(_ ctx: inout GraphicsContext, t: Double) {
        let flying = t < Self.travel
        // Fading trail: where the mote was a moment ago, on the same eased path.
        if flying {
            for k in stride(from: 40, to: 0, by: -1) {
                let tk = t - Double(k) * 0.016
                guard tk > 0 else { continue }
                let q = at(Brass.ease(min(1, tk / Self.travel)))
                let fresh = 1 - Double(k) / 40
                guard k.isMultiple(of: 2) else { continue } // every other step: a dotted, glittery trail
                Sparkle.draw(&ctx, at: q, size: 0.8 + 2.4 * CGFloat(fresh), alpha: fresh * Sparkle.twinkle(t, rate: 14, phase: Double(k)),
                             glint: k % 8 == 0, spin: .radians(Double(k) + t * 2))
            }
            let p = at(Brass.ease(t / Self.travel))
            Brass.glow(&ctx, at: p, radius: 46, alpha: 1)
            return
        }
        // The burst: a quick flash, then sparks flying out and falling.
        let age = t - Self.travel
        let end = points[3]
        Brass.glow(&ctx, at: end, radius: 60 + age * 260, alpha: max(0, 1 - age * 3))
        for s in sparks { s.draw(&ctx, from: end, age: age, life: 1.6) }
    }
}

/// One spark of a burst: a direction, a speed and a size; it glitters, slows and floats down as it fades.
struct Spark {
    var angle: Double
    var speed: CGFloat
    var size: CGFloat
    var glint: Bool
    var phase: Double = .random(in: 0...6.28)

    static func burst(count: Int, speed: ClosedRange<CGFloat>) -> [Spark] {
        (0..<count).map { _ in
            Spark(angle: .random(in: 0...(2 * .pi)), speed: .random(in: speed), size: .random(in: 1.2...3.6), glint: .random(in: 0...1) < 0.3)
        }
    }

    func draw(_ ctx: inout GraphicsContext, from origin: CGPoint, age: Double, life: Double) {
        guard age >= 0, age < life else { return }
        let a = CGFloat(age)
        let drag = (1 - exp(-2.8 * a)) / 2.8 // quick burst, then it hangs in the air
        let x = origin.x + CGFloat(cos(angle)) * speed * drag
        let y = origin.y + CGFloat(sin(angle)) * speed * drag + 70 * a * a // only a gentle settle
        let fade = 1 - age / life
        Sparkle.draw(&ctx, at: CGPoint(x: x, y: y), size: size * CGFloat(0.5 + 0.5 * fade),
                     alpha: fade * Sparkle.twinkle(age, rate: 18, phase: phase), glint: glint, spin: .radians(phase + age * 3))
    }
}

/// A band of warm sunlight that slides across the screen at a random slant.
struct LightLeak {
    var size: CGSize
    var angle: Angle
    var duration: TimeInterval

    static func random(in size: CGSize) -> LightLeak {
        LightLeak(size: size, angle: .degrees(.random(in: -24 ... -8)), duration: .random(in: 3...3.8))
    }

    func draw(_ ctx: inout GraphicsContext, t: Double) {
        let p = min(1, t / duration)
        let a = Brass.envelope(p, fadeIn: 0.3, fadeOut: 0.3)
        guard a > 0.01 else { return }
        let w = size.width, h = size.height
        let band = w * 0.45
        let x = -w * 0.4 + (w * 1.45) * Brass.ease(p)
        var c = ctx
        c.opacity = a
        c.addFilter(.blur(radius: 40))
        c.translateBy(x: x + band / 2, y: h / 2)
        c.rotate(by: angle)
        let rect = CGRect(x: -band / 2, y: -h * 0.8, width: band, height: h * 1.6)
        let warm = Color(red: 1, green: 0.72, blue: 0.38)
        c.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [warm.opacity(0), warm.opacity(0.7), warm.opacity(0)]),
            startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
    }
}


/// A full-screen pendulum of brass light that swings once from left to right.
struct PendulumSwing {
    var size: CGSize
    var amplitude: Double   // degrees either side
    var swing: TimeInterval
    /// Sparks shed by the bob, each released at a moment of the swing.
    var shed: [(at: Double, spark: Spark)]
    static let sparkLife: TimeInterval = 1.3
    /// The swing plus time for the last sparks to fade on their own.
    var duration: TimeInterval { swing + Self.sparkLife + 0.1 }

    static func random(in size: CGSize) -> PendulumSwing {
        let swing = Double.random(in: 2.4...2.9)
        let shed = (0..<220).map { _ in (at: Double.random(in: 0.12...0.88), spark: Spark(
            angle: .random(in: -.pi ... 0), speed: .random(in: 30...170), size: .random(in: 1...3.2), glint: .random(in: 0...1) < 0.3)) }
        return PendulumSwing(size: size, amplitude: .random(in: 34...46), swing: swing, shed: shed)
    }

    /// Where the bob is at progress `p` (0…1) of the swing.
    func bob(at p: Double) -> CGPoint {
        let angle = Angle.degrees(amplitude - 2 * amplitude * Brass.ease(min(1, max(0, p))))
        let pivot = CGPoint(x: size.width / 2, y: 0)
        let length = size.height * 0.6
        return CGPoint(x: pivot.x - sin(angle.radians) * length, y: pivot.y + cos(angle.radians) * length)
    }

    /// Speed of the swing at `p`, 0 at the ends and 1 in the middle.
    private func pace(_ p: Double) -> Double { max(0, sin(.pi * p)) }

    func draw(_ ctx: inout GraphicsContext, t: Double) {
        let p = min(1, max(0, t / swing))
        let eased = Brass.ease(p)
        let angle = Angle.degrees(amplitude - 2 * amplitude * eased)        // + is bob to the left

        // Sparks shed along the way: more where the bob moves fastest. They keep glittering and
        // fade on their own, even after the pendulum itself has gone.
        for (release, spark) in shed where release * swing <= t && pace(release) > Double(spark.size) / 4 {
            spark.draw(&ctx, from: bob(at: release), age: t - release * swing, life: Self.sparkLife)
        }

        // Rod and bob: fade in quickly, then melt away smoothly over the last 40% of the swing.
        let fadeIn = min(1, p / 0.18)
        let out = max(0, (p - 0.6) / 0.4)
        let opacity = fadeIn * (1 - out * out * (3 - 2 * out)) * 0.95  // smoothstep
        guard opacity > 0.01 else { return }

        let pivot = CGPoint(x: size.width / 2, y: 0)
        let length = size.height * 0.6
        let bob = CGPoint(x: pivot.x - sin(angle.radians) * length, y: pivot.y + cos(angle.radians) * length)
        var rod = Path()
        rod.move(to: pivot)
        rod.addLine(to: bob)
        let brass = Color(red: 0.95, green: 0.835, blue: 0.557)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [.init(color: brass.opacity(0), location: 0), .init(color: brass.opacity(0.9), location: 0.7),
                             .init(color: .white, location: 1)]),
            startPoint: pivot, endPoint: bob)
        // Only the rod and bob get a soft shadow, so they hold up on white windows.
        var ctx = ctx
        ctx.opacity = opacity
        ctx.addFilter(.shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 1))
        // Glow, then the rod itself.
        ctx.stroke(rod, with: .color(brass.opacity(0.10)), style: StrokeStyle(lineWidth: 40, lineCap: .round))
        ctx.stroke(rod, with: .color(brass.opacity(0.22)), style: StrokeStyle(lineWidth: 14, lineCap: .round))
        ctx.stroke(rod, with: shading, style: StrokeStyle(lineWidth: 5, lineCap: .round))
        // Bob: a small polished brass weight with a halo.
        let halo = CGRect(x: bob.x - 80, y: bob.y - 80, width: 160, height: 160)
        ctx.fill(Path(ellipseIn: halo), with: .radialGradient(Gradient(colors: [brass.opacity(0.45), brass.opacity(0)]),
                                                               center: bob, startRadius: 0, endRadius: 80))
        let r: CGFloat = 24
        ctx.fill(Path(ellipseIn: CGRect(x: bob.x - r, y: bob.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.96, blue: 0.82), Color(red: 0.85, green: 0.7, blue: 0.37),
                                                         Color(red: 0.54, green: 0.36, blue: 0.13)]),
                                       center: CGPoint(x: bob.x - r * 0.3, y: bob.y - r * 0.3), startRadius: 0, endRadius: r * 1.3))
    }
}

/// Hosts a time-driven drawing for the overlay.
struct ChimeCanvas: View {
    let draw: (inout GraphicsContext, Double) -> Void
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, _ in
                var ctx = ctx
                draw(&ctx, timeline.date.timeIntervalSince(start))
            }
        }
        .ignoresSafeArea()
        .onAppear { start = Date() }
    }
}
