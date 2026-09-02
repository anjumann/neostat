import SwiftUI
import Combine

// MARK: - Glitch text

/// Chromatic-aberration wordmark. Offsets widen under load.
struct GlitchText: View {
    let text: String
    var size: CGFloat = 20
    var tracking: CGFloat = 4
    var active: Bool = false

    private var offset: CGFloat { active ? 1.6 : 0.9 }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .foregroundStyle(Theme.magenta.opacity(0.75))
                .offset(x: -offset, y: active ? 0.6 : 0)
                .blendMode(.plusLighter)
            Text(text)
                .foregroundStyle(Theme.cyan.opacity(0.75))
                .offset(x: offset, y: active ? -0.6 : 0)
                .blendMode(.plusLighter)
            Text(text)
                .foregroundStyle(Theme.textBright)
        }
        .font(Theme.mono(size, .black))
        .tracking(tracking)
        .glow(Theme.cyan, radius: 6, intensity: 0.5)
    }
}

// MARK: - Per-core bar array

struct CoreBars: View {
    let cores: [CoreLoad]
    var height: CGFloat = 46
    var k: CGFloat = 1

    var body: some View {
        HStack(alignment: .bottom, spacing: 3 * k) {
            ForEach(cores) { core in
                VStack(spacing: 3 * k) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.rule.opacity(0.45))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.heat(core.total).opacity(0.55),
                                             Theme.heat(core.total)],
                                    startPoint: .bottom, endPoint: .top
                                )
                            )
                            .frame(height: max(1.5, height * core.total))
                            .glow(Theme.heat(core.total), radius: 3.5,
                                  intensity: 0.35 + core.total * 0.65)
                    }
                    .frame(height: height)

                    Text(core.isEfficiency ? "E" : "P")
                        .font(Theme.mono(6.5 * k, .bold))
                        .foregroundStyle(core.isEfficiency
                                         ? Theme.textGhost
                                         : Theme.textDim.opacity(0.8))
                }
            }
        }
        .modifier(RasterIf())   // one rasterization instead of 2 blur passes per bar
    }
}

// MARK: - Traces

struct Sparkline: View {
    let values: [Double]
    var accent: Color = Theme.cyan
    var k: CGFloat = 1
    var filled: Bool = true
    /// Bloom costs a CPU-side blur per draw; not worth it on tiny traces.
    var shadowed: Bool = true

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let stepX = size.width / CGFloat(values.count - 1)
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: CGFloat(i) * stepX,
                        y: size.height - (size.height * CGFloat(min(max(values[i], 0), 1))))
            }

            var line = Path()
            line.move(to: pt(0))
            for i in 1..<values.count { line.addLine(to: pt(i)) }

            if filled {
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [accent.opacity(0.32), accent.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }

            if shadowed {
                ctx.addFilter(.shadow(color: accent.opacity(0.8), radius: 3 * k))
            }
            ctx.stroke(line, with: .color(accent), lineWidth: 1.2 * k)

            let head = pt(values.count - 1)
            let r = 1.9 * k
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(accent))
        }
    }
}

/// Two rate series on shared auto-scaled axes — used for network and disk.
struct DualAreaGraph: View {
    let inValues: [Double]
    let outValues: [Double]
    var inColor: Color = Theme.cyan
    var outColor: Color = Theme.magenta
    var k: CGFloat = 1
    /// Floor for the auto-scale so an idle link still renders as a flat line.
    var floorValue: Double = 32_768

    var body: some View {
        Canvas { ctx, size in
            let peak = max(inValues.max() ?? 0, outValues.max() ?? 0, floorValue)

            func draw(_ vals: [Double], _ color: Color, mirrored: Bool) {
                guard vals.count > 1 else { return }
                let stepX = size.width / CGFloat(vals.count - 1)
                let half = size.height / 2
                func pt(_ i: Int) -> CGPoint {
                    let n = CGFloat(min(vals[i] / peak, 1))
                    return mirrored
                        ? CGPoint(x: CGFloat(i) * stepX, y: half + n * half)
                        : CGPoint(x: CGFloat(i) * stepX, y: half - n * half)
                }
                var line = Path()
                line.move(to: pt(0))
                for i in 1..<vals.count { line.addLine(to: pt(i)) }

                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: half))
                fill.addLine(to: CGPoint(x: 0, y: half))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(color.opacity(0.22)))

                ctx.addFilter(.shadow(color: color.opacity(0.7), radius: 2.5 * k))
                ctx.stroke(line, with: .color(color), lineWidth: 1.1 * k)
            }

            // centre axis
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }, with: .color(Theme.rule.opacity(0.7)), lineWidth: 0.5)

            draw(inValues, inColor, mirrored: false)
            draw(outValues, outColor, mirrored: true)
        }
    }
}

// MARK: - Per-core grid of individual traces

struct CoreGrid: View {
    let cores: [CoreLoad]
    let series: [Series]
    var columns: Int = 2
    var k: CGFloat = 1
    var sampleCount: Int = 60

    var body: some View {
        let rows = Int(ceil(Double(cores.count) / Double(columns)))
        VStack(spacing: 4 * k) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 5 * k) {
                    ForEach(0..<columns, id: \.self) { c in
                        let idx = r * columns + c
                        if idx < cores.count {
                            cell(cores[idx], idx)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
    }

    private func cell(_ core: CoreLoad, _ idx: Int) -> some View {
        let heat = Theme.heat(core.total)
        return VStack(alignment: .leading, spacing: 1.5 * k) {
            HStack(spacing: 3 * k) {
                Text(core.isEfficiency ? "E\(idx)" : "P\(idx)")
                    .font(Theme.mono(6.5 * k, .bold))
                    .foregroundStyle(core.isEfficiency ? Theme.textGhost : Theme.textDim)
                Spacer(minLength: 0)
                Text(Fmt.pct(core.total))
                    .font(Theme.mono(7 * k, .bold))
                    .foregroundStyle(heat)
            }
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Theme.rule.opacity(0.28))
                if idx < series.count {
                    Sparkline(values: series[idx].tail(sampleCount), accent: heat,
                              k: k * 0.8, shadowed: false)
                }
            }
            .frame(minHeight: 16 * k, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
    }
}

// MARK: - Ring gauge

struct RingGauge: View {
    let value: Double          // 0...1
    let label: String
    let center: String
    var accent: Color = Theme.cyan
    var k: CGFloat = 1
    var thickness: CGFloat = 5

    var body: some View {
        VStack(spacing: 4 * k) {
            ZStack {
                Circle()
                    .stroke(Theme.rule.opacity(0.5), lineWidth: thickness * k)
                Circle()
                    .trim(from: 0, to: max(0.001, min(value, 1)))
                    .stroke(
                        AngularGradient(
                            colors: [accent.opacity(0.45), accent],
                            center: .center,
                            startAngle: .degrees(0), endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: thickness * k, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .glow(accent, radius: 5 * k, intensity: 0.55)
                Text(center)
                    .font(Theme.mono(11 * k, .black))
                    .foregroundStyle(Theme.textBright)
            }

            Text(label)
                .font(Theme.mono(7 * k, .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.textGhost)
        }
    }
}

// MARK: - Segmented memory bar

struct MemoryBar: View {
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let total: UInt64
    var height: CGFloat = 9
    var k: CGFloat = 1

    private struct Seg { let frac: Double; let color: Color }

    private var segments: [Seg] {
        guard total > 0 else { return [] }
        let t = Double(total)
        return [
            Seg(frac: Double(app) / t,        color: Theme.cyan),
            Seg(frac: Double(wired) / t,      color: Theme.magenta),
            Seg(frac: Double(compressed) / t, color: Theme.amber),
        ]
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.rule.opacity(0.4))

                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle()
                            .fill(
                                LinearGradient(colors: [seg.color.opacity(0.65), seg.color],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(width: max(0, w * seg.frac))
                            .glow(seg.color, radius: 3, intensity: 0.5)
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 1.5))

                HStack(spacing: 0) {
                    ForEach(1..<4) { _ in
                        Spacer()
                        Rectangle().fill(Theme.void.opacity(0.85)).frame(width: 1)
                    }
                    Spacer()
                }
            }
        }
        .frame(height: height)
    }
}

/// Simple horizontal meter with a label and value.
struct MeterRow: View {
    let label: String
    let value: String
    let fraction: Double
    var accent: Color = Theme.cyan
    var k: CGFloat = 1
    var labelWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: 6 * k) {
            Text(label)
                .font(Theme.mono(7.5 * k, .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textGhost)
                .frame(width: labelWidth * k, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.rule.opacity(0.45))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(0, geo.size.width * min(max(fraction, 0), 1)))
                        .glow(accent, radius: 3 * k, intensity: 0.5)
                }
            }
            .frame(height: 3 * k)
            Text(value)
                .font(Theme.mono(8 * k, .bold))
                .foregroundStyle(Theme.textDim)
                .frame(width: 52 * k, alignment: .trailing)
        }
    }
}

// MARK: - Legend chip

struct LegendChip: View {
    let color: Color
    let label: String
    let value: String
    var k: CGFloat = 1

    var body: some View {
        HStack(spacing: 4 * k) {
            RoundedRectangle(cornerRadius: 0.5)
                .fill(color)
                .frame(width: 5 * k, height: 5 * k)
                .glow(color, radius: 2.5, intensity: 0.8)
            Text(label)
                .font(Theme.mono(8 * k, .medium))
                .tracking(0.8)
                .foregroundStyle(Theme.textGhost)
            Text(value)
                .font(Theme.mono(8.5 * k, .bold))
                .foregroundStyle(Theme.textDim)
        }
    }
}

// MARK: - I/O throughput row

struct IORow: View {
    let label: String
    let inValue: Double
    let outValue: Double
    var k: CGFloat = 1
    /// Upper bound of the log-scaled activity meter, in bytes/sec.
    var ceiling: Double = 50_000_000

    private func meter(_ v: Double) -> Double {
        guard v > 0 else { return 0 }
        return min(log10(v + 1) / log10(ceiling), 1)
    }

    var body: some View {
        HStack(spacing: 8 * k) {
            Text(label)
                .font(Theme.mono(9 * k, .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.textDim)
                .frame(width: 32 * k, alignment: .leading)

            arrow("▼", Fmt.rate(inValue), meter(inValue), Theme.cyan)
            arrow("▲", Fmt.rate(outValue), meter(outValue), Theme.magenta)
        }
    }

    private func arrow(_ glyph: String, _ text: String, _ level: Double, _ color: Color) -> some View {
        HStack(spacing: 4 * k) {
            Text(glyph)
                .font(Theme.mono(7 * k))
                .foregroundStyle(color.opacity(0.35 + level * 0.65))
                .glow(color, radius: 3, intensity: level)

            Text(text)
                .font(Theme.mono(9.5 * k, .medium))
                .foregroundStyle(Theme.textBright.opacity(0.55 + level * 0.45))
                .frame(width: 46 * k, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.rule.opacity(0.4))
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, geo.size.width * level))
                        .glow(color, radius: 2.5, intensity: level)
                }
            }
            .frame(height: 2.5 * k)
        }
    }
}

// MARK: - Process table

struct ProcessTable: View {
    let rows: [ProcInfo]
    /// Renders CPU percent when true, resident memory when false.
    let showCPU: Bool
    var accent: Color = Theme.cyan
    var k: CGFloat = 1
    var limit: Int = 6
    var nameWidth: CGFloat = 88

    private var maxValue: Double {
        let vals = rows.prefix(limit).map { showCPU ? $0.cpu : Double($0.rss) }
        return max(vals.max() ?? 1, showCPU ? 5 : 1)
    }

    var body: some View {
        VStack(spacing: 3 * k) {
            ForEach(rows.prefix(limit)) { p in
                let v = showCPU ? p.cpu : Double(p.rss)
                let frac = maxValue > 0 ? v / maxValue : 0
                HStack(spacing: 5 * k) {
                    Text(Fmt.clip(p.name, 16))
                        .font(Theme.mono(8 * k, .medium))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: nameWidth * k, alignment: .leading)
                        .lineLimit(1)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.rule.opacity(0.35))
                            Rectangle()
                                .fill(LinearGradient(
                                    colors: [accent.opacity(0.55), accent],
                                    startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(1, geo.size.width * frac))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                    }
                    .frame(height: 6 * k)

                    Text(showCPU
                         ? String(format: "%.1f%%", p.cpu)
                         : Fmt.bytes(p.rss))
                        .font(Theme.mono(8 * k, .bold))
                        .foregroundStyle(Theme.textBright.opacity(0.8))
                        .frame(width: 40 * k, alignment: .trailing)
                }
            }
            if rows.isEmpty {
                Text("SCANNING…")
                    .font(Theme.mono(8 * k))
                    .foregroundStyle(Theme.textGhost)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let label: String
    let value: String
    let active: Bool
    var activeColor: Color = Theme.danger
    var k: CGFloat = 1

    var body: some View {
        HStack(spacing: 5 * k) {
            Circle()
                .fill(active ? activeColor : Theme.textGhost.opacity(0.5))
                .frame(width: 5 * k, height: 5 * k)
                .glow(active ? activeColor : .clear, radius: 4 * k, intensity: active ? 1 : 0)
            Text(label)
                .font(Theme.mono(7.5 * k, .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textGhost)
            Spacer(minLength: 2)
            Text(value)
                .font(Theme.mono(8 * k, .bold))
                .foregroundStyle(active ? activeColor : Theme.textDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 6 * k)
        .padding(.vertical, 3.5 * k)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(active ? activeColor.opacity(0.10) : Theme.rule.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(active ? activeColor.opacity(0.4) : Theme.rule.opacity(0.5),
                              lineWidth: 0.75)
        )
    }
}

/// Compact labelled number for stat strips.
struct StatTile: View {
    let label: String
    let value: String
    var accent: Color = Theme.textBright
    var k: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 1 * k) {
            Text(label)
                .font(Theme.mono(6.5 * k, .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textGhost)
            Text(value)
                .font(Theme.mono(10 * k, .bold))
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Live indicator

struct PulseDot: View {
    let color: Color
    /// Sample counter. Beating on the data tick costs no extra redraws, unlike
    /// a timeline of its own — every redraw of this window is ~10ms whatever
    /// it contains.
    let tick: Int
    var k: CGFloat = 1

    var body: some View {
        let phase: Double = tick % 2 == 0 ? 1.0 : 0.5
        Circle()
            .fill(color)
            .frame(width: 5 * k, height: 5 * k)
            .glow(color, radius: 4 * k, intensity: 0.5 + phase * 0.5)
            .opacity(0.5 + phase * 0.5)
    }
}


// MARK: - Clock

/// Wall clock for the HUD header, in three sizes.
///
/// Where the seconds come from depends on the layout, because redraw *count*
/// is what costs CPU here, not what is being drawn. Compact and wide sample
/// every 0.6s / 0.8s — faster than 1Hz — so reading the wall clock on each
/// sampler tick shows every second without one extra redraw. Dense samples
/// every 1.1s, which would visibly skip seconds, so that size mounts its own
/// 1Hz timeline, and only while the window is on screen.
struct HUDClock: View {
    enum Style {
        case small, medium, large

        var digit: CGFloat {
            switch self { case .small: 13; case .medium: 18; case .large: 26 }
        }
        var colon: CGFloat {
            switch self { case .small: 11; case .medium: 15; case .large: 22 }
        }
        var caption: CGFloat {
            switch self { case .small: 7; case .medium: 7.5; case .large: 8 }
        }
        /// The date line is dropped in compact windows, where the header row
        /// has no vertical room to spare.
        var showsDate: Bool { self != .small }
        var showsZone: Bool { self == .large }
    }

    let k: CGFloat
    let accent: Color
    var style: Style = .large
    /// Sample counter. Non-nil means the HUD around this clock already rebuilds
    /// faster than once a second, so the clock rides that instead of mounting a
    /// timeline of its own.
    var tick: Int? = nil
    /// False when the window is hidden; falls back to a static render.
    var active: Bool = true

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE dd MMM"
        return f
    }()

    private static let zoneFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "zzz"
        return f
    }()

    var body: some View {
        if tick == nil && active {
            TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                face(ctx.date)
            }
        } else {
            face(Date())
        }
    }

    private func face(_ date: Date) -> some View {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        let second = c.second ?? 0
        // Colons pulse with the seconds, which costs nothing extra.
        let lit = second % 2 == 0

        return VStack(alignment: .trailing, spacing: 2 * k) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                digits(Self.pad(hour))
                colon(lit)
                digits(Self.pad(minute))
                colon(lit)
                digits(Self.pad(second), dim: true)
            }

            if style.showsDate {
                HStack(spacing: 5 * k) {
                    Text(Self.dateFormatter.string(from: date).uppercased())
                        .font(Theme.mono(style.caption * k, .bold))
                        .tracking(1.8)
                        .foregroundStyle(Theme.textDim)
                    if style.showsZone {
                        Text("·")
                            .font(Theme.mono(style.caption * k))
                            .foregroundStyle(Theme.rule)
                        Text(Self.zoneFormatter.string(from: date).uppercased())
                            .font(Theme.mono(style.caption * k, .medium))
                            .tracking(1.4)
                            .foregroundStyle(Theme.textGhost)
                    }
                }
            }
        }
        .fixedSize()
    }

    private func digits(_ text: String, dim: Bool = false) -> some View {
        Text(text)
            .font(Theme.mono(style.digit * k, .black))
            .foregroundStyle(dim ? accent.opacity(0.55) : Theme.textBright)
            .glow(accent, radius: 5 * k, intensity: dim ? 0.3 : 0.5)
    }

    private func colon(_ lit: Bool) -> some View {
        Text(":")
            .font(Theme.mono(style.colon * k, .black))
            .foregroundStyle(accent.opacity(lit ? 0.9 : 0.22))
            .padding(.horizontal, 1 * k)
    }

    private static func pad(_ v: Int) -> String {
        v < 10 ? "0\(v)" : "\(v)"
    }
}

// MARK: - Resize grip

struct ResizeGrip: View {
    var k: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            for i in 0..<3 {
                let off = CGFloat(i) * 4 * k
                var p = Path()
                p.move(to: CGPoint(x: size.width - off, y: size.height))
                p.addLine(to: CGPoint(x: size.width, y: size.height - off))
                ctx.stroke(p, with: .color(Theme.textGhost.opacity(0.7)), lineWidth: 1)
            }
        }
        .frame(width: 14 * k, height: 14 * k)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { WindowManager.shared.resizeChanged($0.translation) }
                .onEnded { _ in WindowManager.shared.resizeEnded() }
        )
    }
}
