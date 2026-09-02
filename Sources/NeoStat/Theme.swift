import SwiftUI

/// Runtime feature switches used to profile where frame time actually goes.
/// Set the matching env var to disable an effect, e.g. NEOSTAT_NO_SWEEP=1.
enum Perf {
    static let noSweep     = ProcessInfo.processInfo.environment["NEOSTAT_NO_SWEEP"] != nil
    static let noScanlines = ProcessInfo.processInfo.environment["NEOSTAT_NO_SCANLINES"] != nil
    static let noGlow      = ProcessInfo.processInfo.environment["NEOSTAT_NO_GLOW"] != nil
    static let noAnim      = ProcessInfo.processInfo.environment["NEOSTAT_NO_ANIM"] != nil
    static let noBlur      = ProcessInfo.processInfo.environment["NEOSTAT_NO_BLUR"] != nil
    static let noVibrancy  = ProcessInfo.processInfo.environment["NEOSTAT_NO_VIBRANCY"] != nil
    static let noWinShadow = ProcessInfo.processInfo.environment["NEOSTAT_NO_WINSHADOW"] != nil
    static let noGradient  = ProcessInfo.processInfo.environment["NEOSTAT_NO_GRADIENT"] != nil
    static let noPulse     = ProcessInfo.processInfo.environment["NEOSTAT_NO_PULSE"] != nil
    static let noSample    = ProcessInfo.processInfo.environment["NEOSTAT_NO_SAMPLE"] != nil
    static let noBlend     = ProcessInfo.processInfo.environment["NEOSTAT_NO_BLEND"] != nil
    static let noRaster    = ProcessInfo.processInfo.environment["NEOSTAT_NO_RASTER"] != nil
    static let countRenders = ProcessInfo.processInfo.environment["NEOSTAT_COUNT"] != nil
    static let noCoreGrid  = ProcessInfo.processInfo.environment["NEOSTAT_NO_COREGRID"] != nil
    static let noProcess   = ProcessInfo.processInfo.environment["NEOSTAT_NO_PROCESS"] != nil
    static let noGraphs    = ProcessInfo.processInfo.environment["NEOSTAT_NO_GRAPHS"] != nil
    static let noSensorP   = ProcessInfo.processInfo.environment["NEOSTAT_NO_SENSORP"] != nil
    static let noClock     = ProcessInfo.processInfo.environment["NEOSTAT_NO_CLOCK"] != nil
    /// Force broadcast on at launch, for testing without the pairing panel.
    static let castOn      = ProcessInfo.processInfo.environment["NEOSTAT_CAST"] != nil
    /// Open the pairing panel at launch, so --selftest can render it.
    static let showCast    = ProcessInfo.processInfo.environment["NEOSTAT_SHOW_CAST"] != nil
}

/// Counts how often a deep panel body is rebuilt, to tell "SwiftUI re-evaluated
/// the whole tree" apart from "SwiftUI redrew a few pixels".
enum RenderCount {
    nonisolated(unsafe) static var panels = 0
    nonisolated(unsafe) private static var timer: Timer?

    static func bump() { panels &+= 1 }

    static func startReporting() {
        guard Perf.countRenders, timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let vis = WindowManager.shared.isVisible
            FileHandle.standardError.write("rebuilds/s=\(panels / 2) visible=\(vis)\n".data(using: .utf8)!)
            panels = 0
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

enum Theme {
    // Core palette — cold neon on near-black.
    static let void       = Color(red: 0.024, green: 0.028, blue: 0.055)
    static let panel      = Color(red: 0.055, green: 0.066, blue: 0.110)
    static let cyan       = Color(red: 0.000, green: 0.898, blue: 1.000)
    static let magenta    = Color(red: 1.000, green: 0.180, blue: 0.533)
    static let amber      = Color(red: 1.000, green: 0.702, blue: 0.129)
    static let danger     = Color(red: 1.000, green: 0.208, blue: 0.290)
    static let lime       = Color(red: 0.427, green: 1.000, blue: 0.494)

    // Type tones
    static let textBright = Color(red: 0.847, green: 0.949, blue: 1.000)
    static let textDim    = Color(red: 0.361, green: 0.494, blue: 0.596)
    static let textGhost  = Color(red: 0.204, green: 0.290, blue: 0.376)
    static let rule       = Color(red: 0.114, green: 0.184, blue: 0.259)

    /// Load-reactive color ramp: cyan -> lime -> amber -> magenta -> danger.
    static func heat(_ f: Double) -> Color {
        let v = min(max(f, 0), 1)
        switch v {
        case ..<0.35: return cyan
        case ..<0.55: return lime
        case ..<0.75: return amber
        case ..<0.90: return magenta
        default:      return danger
        }
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Reusable modifiers

extension View {
    /// Neon bloom. Two layered shadows read as light spill rather than a drop
    /// shadow; a third pass costs another full-surface blur for little gain, and
    /// these run on every glowing element of every frame.
    @ViewBuilder
    func glow(_ color: Color, radius: CGFloat = 5, intensity: Double = 0.9) -> some View {
        if Perf.noGlow {
            self
        } else {
            self
                .shadow(color: color.opacity(0.80 * intensity), radius: radius * 0.5)
                .shadow(color: color.opacity(0.38 * intensity), radius: radius * 1.8)
        }
    }
}

// MARK: - Scanlines & grain

struct Scanlines: View {
    var spacing: CGFloat = 3
    var opacity: Double = 0.055

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(.black.opacity(opacity * 8))
                    )
                    y += spacing
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .drawingGroup()          // rasterize once; the pattern never changes
        .allowsHitTesting(false)
        .blendMode(Perf.noBlend ? .normal : .multiply)
    }
}

/// Periodic CRT scan.
///
/// Mounted only while a sweep is actually running. A permanently-running
/// timeline costs one full-window redraw per tick forever; sweeping for 1.2s
/// out of every 7s cuts that to a small average while reading as more
/// deliberate — a radar sweep rather than a constant crawl.
final class SweepScheduler: ObservableObject {
    @Published var active = false

    static let sweepDuration: Double = 1.2
    static let restDuration: Double = 5.8
    static let fps: Double = 15

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        schedule(after: Self.restDuration)
    }

    func stop() {
        timer?.invalidate(); timer = nil; active = false
    }

    private func schedule(after delay: Double) {
        let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.active.toggle()
            self.schedule(after: self.active ? Self.sweepDuration : Self.restDuration)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

struct SweepBeam: View {
    @StateObject private var scheduler = SweepScheduler()

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            if scheduler.active {
                TimelineView(.periodic(from: .now, by: 1.0 / SweepScheduler.fps)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let phase = t.truncatingRemainder(dividingBy: SweepScheduler.sweepDuration)
                        / SweepScheduler.sweepDuration
                    LinearGradient(
                        colors: [.clear, Theme.cyan.opacity(0.14), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 110)
                    .offset(y: (h + 110) * phase - 110)
                    .blendMode(Perf.noBlend ? .normal : .plusLighter)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { scheduler.start() }
        .onDisappear { scheduler.stop() }
    }
}

// MARK: - Panel chrome

/// Corner-bracket frame: four L-shaped ticks instead of a full border.
struct CornerBrackets: View {
    var color: Color = Theme.rule
    var length: CGFloat = 9
    var lineWidth: CGFloat = 1
    var k: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let length = self.length * k
            Path { p in
                // top-left
                p.move(to: CGPoint(x: 0, y: length)); p.addLine(to: .zero)
                p.addLine(to: CGPoint(x: length, y: 0))
                // top-right
                p.move(to: CGPoint(x: w - length, y: 0)); p.addLine(to: CGPoint(x: w, y: 0))
                p.addLine(to: CGPoint(x: w, y: length))
                // bottom-right
                p.move(to: CGPoint(x: w, y: h - length)); p.addLine(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: w - length, y: h))
                // bottom-left
                p.move(to: CGPoint(x: length, y: h)); p.addLine(to: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: 0, y: h - length))
            }
            .stroke(color, lineWidth: lineWidth)
        }
        .allowsHitTesting(false)
    }
}

/// Section header: label, hairline rule, optional right-side value.
struct SectionLabel: View {
    let text: String
    var accent: Color = Theme.textDim
    var trailing: String? = nil
    var k: CGFloat = 1

    var body: some View {
        HStack(spacing: 7 * k) {
            Text(text)
                .font(Theme.mono(8.5 * k, .bold))
                .tracking(2.2 * k)
                .foregroundStyle(accent)
                .fixedSize()
            Rectangle()
                .fill(Theme.rule)
                .frame(height: 1)
            if let trailing {
                Text(trailing)
                    .font(Theme.mono(8.5 * k, .medium))
                    .tracking(1.4 * k)
                    .foregroundStyle(Theme.textGhost)
                    .fixedSize()
            }
        }
    }
}
