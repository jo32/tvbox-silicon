import SwiftUI

/// The three-blade mark putting itself together: a film, a note and a book (what Yingxia plays and reads) pop in one by
/// one where the blades go, each swirls into its blade, then the finished mark spins up and settles. It plays each time it
/// comes on screen (switching back to its tab included) and then holds still, so an idle page does no work.
struct GatherMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped on every appearance; each change plays the keyframes again from the start.
    @State private var plays = 0

    var body: some View {
        Group {
            if reduceMotion {
                GatherMarkFrame(time: GatherTimeline.duration)
            } else {
                KeyframeAnimator(initialValue: 0.0, trigger: plays) { time in
                    GatherMarkFrame(time: time)
                } keyframes: { _ in
                    KeyframeTrack {
                        MoveKeyframe(0.0)
                        LinearKeyframe(GatherTimeline.duration, duration: GatherTimeline.duration)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .onAppear { plays += 1 }
    }
}

/// One moment of the animation, `time` seconds in.
struct GatherMarkFrame: View {
    var time: Double

    private static let symbols = ["music.note", "book.fill"]
    /// Where a blade's centre of mass sits in the mark's 920-unit square (blade 0, before it is turned).
    private static let bladeCenter = CGPoint(x: -6.7, y: -212.1)

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let unit = side / 920
            let anchor = UnitPoint(x: 0.5 + Self.bladeCenter.x / 920, y: 0.5 + Self.bladeCenter.y / 920)
            ZStack {
                RadialGradient(colors: [Brand.cyan.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: side * 0.62)
                    .frame(width: side * 1.5, height: side * 1.5)
                    .opacity(GatherTimeline.glow(time))
                LinearGradient(colors: [Brand.cyan, Brand.teal, Brand.indigo], startPoint: .top, endPoint: .bottom)
                    .mask {
                        ZStack {
                            ForEach(0..<3, id: \.self) { k in
                                let turn = Angle.degrees(120 * Double(k))
                                ZStack {
                                    GatherBlade()
                                        .scaleEffect(GatherTimeline.bladeScale(time, k), anchor: anchor)
                                        .rotationEffect(.degrees(GatherTimeline.bladeTurn(time, k)), anchor: anchor)
                                    icon(k, unit: unit)
                                        .scaleEffect(GatherTimeline.iconScale(time, k))
                                        .rotationEffect(.degrees(GatherTimeline.iconTurn(time, k)))
                                        .rotationEffect(-turn)
                                        .offset(x: Self.bladeCenter.x * unit, y: Self.bladeCenter.y * unit)
                                }
                                .rotationEffect(turn)
                            }
                        }
                        .rotationEffect(.degrees(GatherTimeline.spin(time)))
                        .scaleEffect(GatherTimeline.pulse(time))
                    }
                    .frame(width: side, height: side)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

extension GatherMarkFrame {
    /// The film frame is drawn (the SF film symbol has no play button); the note and the book are SF Symbols.
    @ViewBuilder private func icon(_ k: Int, unit: CGFloat) -> some View {
        if k == 0 {
            GatherFilm().fill(style: FillStyle(eoFill: true)).frame(width: 236 * unit, height: 184 * unit)
        } else {
            Image(systemName: Self.symbols[k - 1]).font(.system(size: 200 * unit, weight: .semibold))
        }
    }
}

/// A film frame: sprocket holes along both edges and a play button cut out of the middle.
struct GatherFilm: Shape {
    func path(in rect: CGRect) -> Path {
        let u = rect.width / 236
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * u, y: rect.minY + y * u, width: w * u, height: h * u)
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
        var path = Path(roundedRect: r(0, 0, 236, 184), cornerRadius: 26 * u, style: .continuous)
        for i in 0..<5 {
            let x = 24 + 42 * CGFloat(i)
            path.addRoundedRect(in: r(x, 18, 20, 18), cornerSize: CGSize(width: 5 * u, height: 5 * u))
            path.addRoundedRect(in: r(x, 148, 20, 18), cornerSize: CGSize(width: 5 * u, height: 5 * u))
        }
        // The play button, its corners softened.
        path.move(to: p(94, 58))
        path.addQuadCurve(to: p(101, 54), control: p(94, 50))
        path.addLine(to: p(154, 86))
        path.addQuadCurve(to: p(154, 98), control: p(160, 92))
        path.addLine(to: p(101, 130))
        path.addQuadCurve(to: p(94, 126), control: p(94, 134))
        path.closeSubpath()
        return path
    }
}

/// The timeline in seconds. Each piece starts half a second after the one before it.
enum GatherTimeline {
    static let duration = 4.6
    private static let spinStart = 2.85, spinLength = 1.4

    private static func start(_ k: Int) -> Double { 0.15 + 0.5 * Double(k) }
    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    /// Eases out past 1 and back: the pop of a piece arriving.
    private static func backOut(_ x: Double, overshoot c: Double = 1.4) -> Double { 1 + (c + 1) * pow(x - 1, 3) + c * pow(x - 1, 2) }

    /// An icon pops in, holds, then turns away as it shrinks.
    static func iconScale(_ t: Double, _ k: Int) -> Double {
        let a = start(k)
        guard t > a else { return 0 }
        if t < a + 0.4 { return backOut((t - a) / 0.4) }
        return 1 - easeInOut(clamp((t - a - 0.9) / 0.45))
    }

    static func iconTurn(_ t: Double, _ k: Int) -> Double { 80 * easeInOut(clamp((t - start(k) - 0.9) / 0.45)) }

    /// The blade swirls in from where its icon turned away.
    static func bladeScale(_ t: Double, _ k: Int) -> Double {
        let p = clamp((t - start(k) - 1.0) / 0.55)
        return p == 0 ? 0 : backOut(p, overshoot: 0.8)
    }

    static func bladeTurn(_ t: Double, _ k: Int) -> Double { -80 * (1 - backOut(clamp((t - start(k) - 1.0) / 0.55), overshoot: 0.8)) }

    /// Two full turns once all three blades are in.
    static func spin(_ t: Double) -> Double { 720 * easeInOut(clamp((t - spinStart) / spinLength)) }

    /// A small swell as the spin lands.
    static func pulse(_ t: Double) -> Double {
        let p = clamp((t - spinStart - spinLength) / (duration - spinStart - spinLength))
        return 1 + 0.06 * sin(p * .pi)
    }

    static func glow(_ t: Double) -> Double { clamp(t / 1.5) }
}

/// One blade of the mark, drawn in a 920-unit square centred on the mark (Design/svg-logo).
struct GatherBlade: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 920
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.midX + x * unit, y: rect.midY + y * unit) }
        var path = Path()
        path.move(to: point(-60.48, -341.44))
        for c in Self.curves {
            path.addCurve(to: point(c.4, c.5), control1: point(c.0, c.1), control2: point(c.2, c.3))
        }
        path.closeSubpath()
        return path
    }

    private static let curves: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (-24.73, -368.59, 24.73, -368.59, 60.48, -341.44),
        (123.81, -293.35, 178.28, -234.61, 221.47, -167.84),
        (224.87, -162.59, 224.54, -155.76, 220.66, -150.86),
        (216.78, -145.96, 210.21, -144.07, 204.32, -146.17),
        (88.36, -187.46, -40.71, -142.39, -105.76, -37.89),
        (-110.53, -30.24, -119.23, -25.98, -128.19, -26.89),
        (-137.16, -27.80, -144.83, -33.74, -147.95, -42.20),
        (-187.79, -150.20, -152.41, -271.55, -60.77, -341.22),
    ]
}
