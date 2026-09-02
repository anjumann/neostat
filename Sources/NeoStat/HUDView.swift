import SwiftUI
import Combine

// NOTE: `@State` is unavailable in this toolchain — on the macOS 27 SDK it is a
// macro whose plugin ships only with full Xcode, not Command Line Tools. View
// state therefore lives in small ObservableObjects driven through @StateObject.

/// Rebuilds `content` only when `key` changes.
///
/// Process and sensor data refresh every 2s while the HUD ticks faster than
/// that, so without this those panels are rebuilt from scratch several times
/// per second for identical output.
struct Memo<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder var content: () -> Content

    static func == (a: Memo, b: Memo) -> Bool { a.key == b.key }
    var body: some View { content() }
}

private struct ProcKey: Equatable {
    let k: CGFloat
    let mode: Metrics.Mode
    let accent: Color
    let cpu: [ProcInfo]
    let mem: [ProcInfo]
    let count: Int
}

private struct SensorKey: Equatable {
    let k: CGFloat
    let mode: Metrics.Mode
    let accent: Color
    let sensors: Sensors
}

/// Applies `.drawingGroup()` unless rasterization is being profiled out.
struct RasterIf: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if Perf.noRaster { content } else { content.drawingGroup() }
    }
}

// MARK: - Responsive metrics

struct Metrics: Equatable {
    enum Mode { case compact, wide, dense }

    /// Sampling period suited to how much this layout costs to rebuild.
    var cadence: TimeInterval {
        switch mode {
        case .compact: return 0.6
        case .wide:    return 0.8
        case .dense:   return 1.1
        }
    }

    let size: CGSize
    let mode: Mode
    let k: CGFloat
    let history: Int
    let corner: CGFloat

    // Which optional panels this window is tall enough to carry.
    let showCPUTiles: Bool
    let showSystem: Bool
    let showSensors: Bool
    let showProcesses: Bool
    let showGauges: Bool
    let showCoreGrid: Bool
    let showMemDetail: Bool
    /// Which size of clock the header carries, nil when it is switched off.
    let clock: HUDClock.Style?

    init(size: CGSize, fullScreen: Bool) {
        self.size = size
        let h = size.height

        if size.width >= 1080 { mode = .dense }
        else if size.width >= 620 { mode = .wide }
        else { mode = .compact }

        showCPUTiles  = h >= 460
        showMemDetail = mode != .compact
        showSystem    = mode != .compact && h >= 520
        showSensors   = h >= (mode == .compact ? 720 : 600) && !Perf.noSensorP
        showProcesses = (mode == .dense ? h >= 560 : h >= 820) && !Perf.noProcess
        showGauges    = mode == .dense ? h >= 680 : h >= 940
        showCoreGrid  = mode == .dense && h >= 620 && !Perf.noCoreGrid
        if Perf.noClock {
            clock = nil
        } else {
            switch mode {
            case .compact: clock = .small
            case .wide:    clock = .medium
            case .dense:   clock = .large
            }
        }

        // Estimated unscaled height of each panel, used to pick a scale that
        // makes the tallest column actually fit rather than overflow.
        let cpuH        = showCPUTiles ? 232.0 : 196.0
        let coreGridH   = 190.0
        let memH        = showMemDetail ? 168.0 : 104.0
        let gaugesH     = 96.0
        let throughputH = mode == .compact ? 62.0 : 118.0
        let systemH     = 84.0
        let processH    = mode == .dense ? 228.0 : 152.0
        let sensorsH    = 156.0
        let gutter      = 10.0

        func stack(_ parts: [Double]) -> Double {
            parts.isEmpty ? 0 : parts.reduce(0, +) + gutter * Double(parts.count - 1)
        }

        var column: Double
        var extraRows: Double = 0

        switch mode {
        case .compact:
            column = stack([cpuH, memH, throughputH] + (showSensors ? [sensorsH] : []))
        case .wide:
            let left = stack([cpuH]
                             + (showSystem ? [systemH] : [])
                             + (showProcesses ? [processH] : []))
            let right = stack([memH]
                              + (showGauges ? [gaugesH] : [])
                              + [throughputH]
                              + (showSensors ? [sensorsH] : []))
            column = max(left, right)
        case .dense:
            let c1 = stack([cpuH] + (showCoreGrid ? [coreGridH] : []))
            let c2 = stack([memH]
                           + (showGauges ? [gaugesH] : [])
                           + (showSystem ? [systemH] : []))
            let c3 = stack((showProcesses ? [processH] : [])
                           + (showSensors ? [sensorsH] : []))
            column = max(c1, max(c2, c3))
            extraRows = throughputH + gutter
        }

        // header + footer + window padding + inter-section gutters
        let chrome = 46.0 + 22.0 + 22.0 + gutter * 2
        let estimated = max(column + extraRows + chrome, 320)

        let columns: CGFloat = mode == .dense ? 3 : (mode == .wide ? 2 : 1)
        let columnWidth = size.width / columns
        k = min(max(min(columnWidth / 300, h / CGFloat(estimated)), 0.72), 2.4)

        history = Int(min(max(size.width / 8, 48), 130))
        corner = fullScreen ? 0 : 12
    }

    var gutter: CGFloat { 10 * k }
}

// MARK: - Boot sequence

final class BootState: ObservableObject {
    @Published var shown = 0
    @Published var caret = true

    private var caretTimer: Timer?
    private var started = false

    let lines = [
        "INIT KERNEL BRIDGE",
        "MAP host_processor_info",
        "LINK vm_statistics64",
        "ATTACH IOBlockStorageDriver",
        "PROBE IOAccelerator",
        "SCAN POWER / OPTICS / AUDIO",
        "ENUMERATE TASK TABLE",
    ]

    func run(onFinish: @escaping () -> Void) {
        guard !started else { return }
        started = true

        for i in 0...lines.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13 * Double(i)) { [weak self] in
                withAnimation(.easeOut(duration: 0.16)) { self?.shown = i + 1 }
            }
        }

        let t = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.caret.toggle()
        }
        RunLoop.main.add(t, forMode: .common)
        caretTimer = t

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13 * Double(lines.count) + 0.5) {
            [weak self] in
            self?.caretTimer?.invalidate()
            self?.caretTimer = nil
            onFinish()
        }
    }
}

struct BootView: View {
    @StateObject private var st = BootState()
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GlitchText(text: "NEOSTAT", size: 22, tracking: 6, active: true)
                .padding(.bottom, 4)

            ForEach(0..<st.lines.count, id: \.self) { i in
                if i < st.shown {
                    HStack(spacing: 6) {
                        Text("›")
                            .font(Theme.mono(9, .bold))
                            .foregroundStyle(Theme.magenta)
                        Text(st.lines[i])
                            .font(Theme.mono(9))
                            .tracking(0.8)
                            .foregroundStyle(Theme.textDim)
                        Rectangle().fill(Theme.rule).frame(height: 1)
                        Text("OK")
                            .font(Theme.mono(9, .bold))
                            .foregroundStyle(Theme.lime)
                            .glow(Theme.lime, radius: 3, intensity: 0.6)
                    }
                    .transition(.opacity.combined(with: .offset(x: -6)))
                }
            }

            if st.shown > st.lines.count {
                HStack(spacing: 6) {
                    Text("NEOSTAT ONLINE")
                        .font(Theme.mono(10, .bold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.cyan)
                        .glow(Theme.cyan, radius: 5, intensity: 0.7)
                    Text("█")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.cyan)
                        .opacity(st.caret ? 1 : 0)
                }
                .padding(.top, 3)
                .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { st.run(onFinish: onFinish) }
    }
}

// MARK: - HUD view state

/// Only the boot flag lives here now. Continuous animation phases were moved
/// into the views that use them; published here, each frame re-evaluated the
/// whole HUD body.
final class UIState: ObservableObject {
    @Published var booted = false
    @Published var showCast = Perf.showCast
}

// MARK: - Main HUD

struct HUDView: View {
    @StateObject private var mon = SystemMonitor()
    @StateObject private var ui = UIState()
    @ObservedObject private var win = WindowManager.shared
    @ObservedObject private var cast = Broadcast.shared

    private var s: Snapshot { mon.snap }
    private var accent: Color { s.isStressed ? Theme.danger : Theme.cyan }

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(size: geo.size, fullScreen: win.isFullScreen)

            ZStack {
                background

                Group {
                    if ui.booted {
                        content(m).transition(.opacity)
                    } else {
                        BootView {
                            withAnimation(.easeInOut(duration: 0.45)) { ui.booted = true }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 14 * m.k)
                .padding(.top, 12 * m.k)
                .padding(.bottom, 10 * m.k)

                // Both are pure overlay compositing; skipping them while the
                // window is in motion keeps the drag smooth.
                if !win.isDragging && win.isVisible {
                    if !Perf.noSweep { SweepBeam() }
                    if !Perf.noScanlines { Scanlines() }
                }

                RoundedRectangle(cornerRadius: m.corner)
                    .strokeBorder(accent.opacity(0.28), lineWidth: 1)
                    .glow(accent, radius: 6, intensity: 0.35)

                if ui.showCast {
                    Color.black.opacity(0.6)
                        .contentShape(Rectangle())
                        .onTapGesture { ui.showCast = false }
                        .noDrag()
                    CastPanel(k: min(max(m.k, 0.9), 1.3), accent: accent) {
                        ui.showCast = false
                    }
                }

                // Kept outside the draggable layer so its gesture wins.
                if !win.isFullScreen {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ResizeGrip(k: m.k).padding(4 * m.k).noDrag()
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: m.corner))
            .coordinateSpace(name: HUDSpace.name)
            .onPreferenceChange(NoDragKey.self) { rects in
                WindowManager.shared.noDragRects = rects
            }
            .onChange(of: m.cadence) { mon.setInterval($0) }
            .onAppear { mon.setInterval(m.cadence) }
        }
        .onAppear {
            mon.start()
            RenderCount.startReporting()
        }
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            Theme.void
            if !Perf.noGradient {
                RadialGradient(colors: [accent.opacity(0.14), .clear],
                               center: .top, startRadius: 0, endRadius: 400)
                RadialGradient(colors: [Theme.magenta.opacity(0.10), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: 380)
            }
        }
        .modifier(RasterIf())   // cache the full-window gradients as one texture
    }

    // MARK: Layout router

    @ViewBuilder
    private func content(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: m.gutter) {
            header(m)

            Group {
                switch m.mode {
                case .compact: compactBody(m)
                case .wide:    wideBody(m)
                case .dense:   denseBody(m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()

            footer(m)
        }
    }

    private func compactBody(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: m.gutter) {
            cpuPanel(m)
            memPanel(m)
            throughputPanel(m)
            if m.showSensors { sensorPanel(m) }
            Spacer(minLength: 0)
        }
    }

    private func wideBody(_ m: Metrics) -> some View {
        HStack(alignment: .top, spacing: m.gutter) {
            VStack(alignment: .leading, spacing: m.gutter) {
                cpuPanel(m)
                if m.showSystem { systemPanel(m) }
                if m.showProcesses { processPanel(m) }
            }
            VStack(alignment: .leading, spacing: m.gutter) {
                memPanel(m)
                if m.showGauges { gaugesPanel(m) }
                throughputPanel(m)
                if m.showSensors { sensorPanel(m) }
            }
        }
    }

    private func denseBody(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: m.gutter) {
            HStack(alignment: .top, spacing: m.gutter) {
                VStack(alignment: .leading, spacing: m.gutter) {
                    cpuPanel(m)
                    if m.showCoreGrid { coreGridPanel(m) }
                }
                VStack(alignment: .leading, spacing: m.gutter) {
                    memPanel(m)
                    if m.showGauges { gaugesPanel(m) }
                    if m.showSystem { systemPanel(m) }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: m.gutter) {
                    if m.showProcesses { processPanel(m) }
                    if m.showSensors { sensorPanel(m) }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            throughputPanel(m)
        }
    }

    // MARK: Panel chrome

    private func panelBox<C: View>(_ m: Metrics, flexible: Bool = false,
                                   @ViewBuilder _ inner: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7 * m.k) { inner() }
            .padding(.vertical, 9 * m.k)
            .padding(.horizontal, 10 * m.k)
            .frame(maxWidth: .infinity,
                   maxHeight: flexible ? .infinity : nil,
                   alignment: .topLeading)
            .background(Theme.panel.opacity(0.5))
            .overlay(CornerBrackets(color: accent.opacity(0.45), k: m.k))
    }

    // MARK: Header

    private func header(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 5 * m.k) {
            HStack(alignment: .firstTextBaseline) {
                GlitchText(text: "NEOSTAT", size: 19 * m.k, tracking: 5 * m.k,
                           active: s.isStressed)
                Spacer()
                if let style = m.clock {
                    // Dense samples slower than 1Hz, so only that size needs a
                    // timeline of its own; the others ride the sampler tick.
                    HUDClock(k: m.k, accent: accent, style: style,
                             tick: m.mode == .dense ? nil : s.tick,
                             active: win.isVisible)
                        .padding(.trailing, 8 * m.k)
                }
                Button(action: { ui.showCast.toggle() }) {
                    Image(systemName: cast.isOn
                          ? "antenna.radiowaves.left.and.right"
                          : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 11 * m.k, weight: .bold))
                        .foregroundStyle(cast.isOn
                                         ? (cast.clients > 0 ? Theme.lime : Theme.cyan)
                                         : Theme.textGhost)
                        .padding(4 * m.k)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .noDrag()
                .help(cast.isOn ? "Broadcasting — \(cast.clients) device(s)" : "Broadcast to phone / tablet / watch")

                Button(action: { WindowManager.shared.toggleFullScreen() }) {
                    Image(systemName: win.isFullScreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11 * m.k, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                        .padding(4 * m.k)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .noDrag()
                .help(win.isFullScreen ? "Exit full screen (Esc)" : "Full screen")

                Button(action: { NSApp.terminate(nil) }) {
                    Text("✕")
                        .font(Theme.mono(12 * m.k, .bold))
                        .foregroundStyle(Theme.textGhost)
                        .padding(4 * m.k)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .noDrag()
                .help("Quit NeoStat")
            }

            HStack(spacing: 6 * m.k) {
                Text(Fmt.shortChip(s.chip))
                    .font(Theme.mono(8.5 * m.k, .bold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.textDim)
                sep
                Text("\(s.coreCount)C")
                    .font(Theme.mono(8.5 * m.k, .medium))
                    .foregroundStyle(Theme.textGhost)
                sep
                Text("\(Fmt.gb0(s.memTotal))GB")
                    .font(Theme.mono(8.5 * m.k, .medium))
                    .foregroundStyle(Theme.textGhost)
                if m.mode != .compact {
                    sep
                    Text(Fmt.clip(s.hostName.uppercased(), 20))
                        .font(Theme.mono(8.5 * m.k, .medium))
                        .foregroundStyle(Theme.textGhost)
                    sep
                    Text("\(s.procCount) TASKS")
                        .font(Theme.mono(8.5 * m.k, .medium))
                        .foregroundStyle(Theme.textGhost)
                }
                Spacer()
                PulseDot(color: s.isStressed ? Theme.danger : Theme.lime, tick: s.tick, k: m.k)
            }
        }
        .contentShape(Rectangle())
    }

    private var sep: some View {
        Text("·").font(Theme.mono(8.5)).foregroundStyle(Theme.rule)
    }

    // MARK: CPU

    private func cpuPanel(_ m: Metrics) -> some View {
        RenderCount.bump()
        return panelBox(m, flexible: true) {
            SectionLabel(text: "PROCESSOR", accent: accent.opacity(0.85),
                         trailing: s.isStressed ? "⚠ LOAD" : "NOMINAL", k: m.k)

            HStack(alignment: .lastTextBaseline, spacing: 5 * m.k) {
                Text(Fmt.pct(s.cpuTotal))
                    .font(Theme.mono(34 * m.k, .black))
                    .foregroundStyle(Theme.heat(s.cpuTotal))
                    .glow(Theme.heat(s.cpuTotal), radius: 7, intensity: 0.55)
                Text("%")
                    .font(Theme.mono(13 * m.k, .bold))
                    .foregroundStyle(Theme.heat(s.cpuTotal).opacity(0.55))

                Spacer()

                VStack(alignment: .trailing, spacing: 2 * m.k) {
                    kv("USR", Fmt.pct(s.cpuUser), Theme.cyan, m)
                    kv("SYS", Fmt.pct(s.cpuSystem), Theme.magenta, m)
                }
            }

            Sparkline(values: s.cpuSeries.tail(m.history),
                      accent: Theme.heat(s.cpuTotal), k: m.k)
                .frame(minHeight: (m.mode == .compact ? 28 : 40) * m.k,
                       maxHeight: (m.mode == .compact ? 66 : 190) * m.k)

            CoreBars(cores: s.cores, height: 42 * m.k, k: m.k)

            if m.showCPUTiles {
            HStack(spacing: 8 * m.k) {
                StatTile(label: "LOAD 1M", value: String(format: "%.2f", s.loadAvg.0),
                         accent: Theme.textBright, k: m.k)
                StatTile(label: "5M", value: String(format: "%.2f", s.loadAvg.1),
                         accent: Theme.textDim, k: m.k)
                StatTile(label: "15M", value: String(format: "%.2f", s.loadAvg.2),
                         accent: Theme.textDim, k: m.k)
                StatTile(label: "PEAK", value: Fmt.pct(s.cpuSeries.peak) + "%",
                         accent: Theme.amber, k: m.k)
            }
            }
        }
    }

    private func kv(_ key: String, _ value: String, _ c: Color, _ m: Metrics) -> some View {
        HStack(spacing: 5 * m.k) {
            Text(key)
                .font(Theme.mono(7.5 * m.k, .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.textGhost)
            Text(value + "%")
                .font(Theme.mono(10 * m.k, .bold))
                .foregroundStyle(c)
        }
    }

    // MARK: Per-core grid

    private func coreGridPanel(_ m: Metrics) -> some View {
        panelBox(m, flexible: true) {
            SectionLabel(text: "CORE MATRIX", accent: accent.opacity(0.85),
                         trailing: "\(s.coreCount) LOGICAL", k: m.k)
            CoreGrid(cores: s.cores, series: s.coreSeries,
                     columns: 2, k: m.k, sampleCount: min(m.history, 56))
        }
    }

    // MARK: Memory

    private func memPanel(_ m: Metrics) -> some View {
        panelBox(m, flexible: m.showMemDetail) {
            SectionLabel(text: "MEMORY", accent: accent.opacity(0.85),
                         trailing: "PRESSURE \(s.pressureLabel)", k: m.k)

            HStack(alignment: .lastTextBaseline, spacing: 5 * m.k) {
                Text(Fmt.pct(s.memFraction))
                    .font(Theme.mono(22 * m.k, .black))
                    .foregroundStyle(Theme.heat(s.memFraction))
                    .glow(Theme.heat(s.memFraction), radius: 5, intensity: 0.5)
                Text("%")
                    .font(Theme.mono(10 * m.k, .bold))
                    .foregroundStyle(Theme.heat(s.memFraction).opacity(0.55))
                Spacer()
                Text("\(Fmt.gb(s.memUsed)) / \(Fmt.gb(s.memTotal)) GB")
                    .font(Theme.mono(10 * m.k, .medium))
                    .foregroundStyle(Theme.textDim)
            }

            MemoryBar(app: s.memApp, wired: s.memWired,
                      compressed: s.memCompressed, total: s.memTotal,
                      height: 9 * m.k, k: m.k)

            HStack(spacing: 10 * m.k) {
                LegendChip(color: Theme.cyan, label: "APP", value: Fmt.gb(s.memApp), k: m.k)
                LegendChip(color: Theme.magenta, label: "WIRE", value: Fmt.gb(s.memWired), k: m.k)
                LegendChip(color: Theme.amber, label: "COMP", value: Fmt.gb(s.memCompressed), k: m.k)
                Spacer()
            }

            if m.showMemDetail {
                Sparkline(values: s.memSeries.tail(m.history),
                          accent: Theme.heat(s.memFraction), k: m.k)
                    .frame(minHeight: 22 * m.k, maxHeight: 54 * m.k)

                MeterRow(label: "SWAP", value: "\(Fmt.bytes(s.swapUsed))",
                         fraction: s.swapFraction, accent: Theme.amber, k: m.k)
                MeterRow(label: "CACHE", value: Fmt.bytes(s.memCached),
                         fraction: s.memTotal > 0 ? Double(s.memCached) / Double(s.memTotal) : 0,
                         accent: Theme.lime, k: m.k)
            }
        }
    }

    // MARK: Gauges

    private func gaugesPanel(_ m: Metrics) -> some View {
        panelBox(m) {
            SectionLabel(text: "SUBSYSTEMS", accent: accent.opacity(0.85),
                         trailing: s.gpuAvailable ? "GPU LIVE" : "GPU N/A", k: m.k)
            HStack(spacing: 10 * m.k) {
                RingGauge(value: s.gpuUtil, label: "GPU",
                          center: Fmt.pct(s.gpuUtil), accent: Theme.heat(s.gpuUtil),
                          k: m.k, thickness: 5)
                    .frame(width: (m.mode == .dense ? 60 : 52) * m.k, height: (m.mode == .dense ? 76 : 66) * m.k)
                RingGauge(value: s.volFraction, label: "DISK",
                          center: Fmt.pct(s.volFraction), accent: Theme.cyan,
                          k: m.k, thickness: 5)
                    .frame(width: (m.mode == .dense ? 60 : 52) * m.k, height: (m.mode == .dense ? 76 : 66) * m.k)
                RingGauge(value: Double(s.sensors.percent) / 100,
                          label: s.sensors.hasBattery ? "BATT" : "PWR",
                          center: s.sensors.hasBattery ? "\(s.sensors.percent)" : "AC",
                          accent: s.sensors.percent < 20 ? Theme.danger : Theme.lime,
                          k: m.k, thickness: 5)
                    .frame(width: (m.mode == .dense ? 60 : 52) * m.k, height: (m.mode == .dense ? 76 : 66) * m.k)
                RingGauge(value: s.memFraction, label: "MEM",
                          center: Fmt.pct(s.memFraction),
                          accent: Theme.heat(s.memFraction), k: m.k, thickness: 5)
                    .frame(width: (m.mode == .dense ? 60 : 52) * m.k, height: (m.mode == .dense ? 76 : 66) * m.k)
                Spacer(minLength: 0)
            }
            if s.gpuAvailable {
                Sparkline(values: s.gpuSeries.tail(m.history),
                          accent: Theme.heat(s.gpuUtil), k: m.k)
                    .frame(minHeight: 22 * m.k, maxHeight: 54 * m.k)
            }
        }
    }

    // MARK: Throughput

    private func throughputPanel(_ m: Metrics) -> some View {
        panelBox(m, flexible: m.mode != .compact) {
            SectionLabel(text: "THROUGHPUT", accent: accent.opacity(0.85),
                         trailing: "PER SECOND", k: m.k)

            if m.mode == .compact || Perf.noGraphs {
                IORow(label: "NET", inValue: s.netRx, outValue: s.netTx, k: m.k)
                IORow(label: "DISK", inValue: s.diskRead, outValue: s.diskWrite,
                      k: m.k, ceiling: 2_000_000_000)
            } else {
                HStack(alignment: .top, spacing: 14 * m.k) {
                    graphBlock(m, title: "NETWORK",
                               down: s.netRx, up: s.netTx,
                               downSeries: s.netRxSeries, upSeries: s.netTxSeries,
                               floorValue: 32_768)
                    graphBlock(m, title: "DISK",
                               down: s.diskRead, up: s.diskWrite,
                               downSeries: s.diskReadSeries, upSeries: s.diskWriteSeries,
                               floorValue: 1_048_576)
                }
            }
        }
    }

    private func graphBlock(_ m: Metrics, title: String,
                            down: Double, up: Double,
                            downSeries: Series, upSeries: Series,
                            floorValue: Double) -> some View {
        VStack(alignment: .leading, spacing: 4 * m.k) {
            HStack(spacing: 6 * m.k) {
                Text(title)
                    .font(Theme.mono(7.5 * m.k, .bold))
                    .tracking(1.3)
                    .foregroundStyle(Theme.textGhost)
                    .fixedSize()
                Spacer(minLength: 4 * m.k)
                Text("▼ " + Fmt.rate(down))
                    .font(Theme.mono(8.5 * m.k, .bold))
                    .foregroundStyle(Theme.cyan)
                    .fixedSize()
                Text("▲ " + Fmt.rate(up))
                    .font(Theme.mono(8.5 * m.k, .bold))
                    .foregroundStyle(Theme.magenta)
                    .fixedSize()
            }
            DualAreaGraph(inValues: downSeries.tail(m.history),
                          outValues: upSeries.tail(m.history),
                          k: m.k, floorValue: floorValue)
                .frame(minHeight: 44 * m.k, maxHeight: 110 * m.k)
            Text("PEAK ▼ \(Fmt.rate(downSeries.peak))   ▲ \(Fmt.rate(upSeries.peak))")
                .font(Theme.mono(7 * m.k))
                .foregroundStyle(Theme.textGhost)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Processes

    private func processPanel(_ m: Metrics) -> some View {
        Memo(key: ProcKey(k: m.k, mode: m.mode, accent: accent,
                          cpu: s.topCPU, mem: s.topMem, count: s.procCount)) {
            processPanelBody(m)
        }
        .equatable()
    }

    private func processPanelBody(_ m: Metrics) -> some View {
        panelBox(m) {
            SectionLabel(text: "TOP TASKS · CPU", accent: accent.opacity(0.85),
                         trailing: "\(s.procCount) PROC", k: m.k)
            ProcessTable(rows: s.topCPU, showCPU: true,
                         accent: Theme.magenta, k: m.k, limit: m.mode == .dense ? 8 : 5)

            SectionLabel(text: "TOP TASKS · MEM", accent: accent.opacity(0.85),
                         trailing: "RESIDENT", k: m.k)
            ProcessTable(rows: s.topMem, showCPU: false,
                         accent: Theme.cyan, k: m.k, limit: m.mode == .dense ? 8 : 5)
        }
    }

    // MARK: Sensors

    private func sensorPanel(_ m: Metrics) -> some View {
        Memo(key: SensorKey(k: m.k, mode: m.mode, accent: accent, sensors: s.sensors)) {
            sensorPanelBody(m)
        }
        .equatable()
    }

    private func sensorPanelBody(_ m: Metrics) -> some View {
        panelBox(m) {
            SectionLabel(text: "SENSORS", accent: accent.opacity(0.85),
                         trailing: s.sensors.thermalLabel, k: m.k)

            StatusPill(label: "CAMERA",
                       value: s.sensors.cameraActive ? "IN USE" : "IDLE",
                       active: s.sensors.cameraActive,
                       activeColor: Theme.danger, k: m.k)
            StatusPill(label: "MIC",
                       value: s.sensors.micActive ? Fmt.clip(s.sensors.micName.uppercased(), 14) : "IDLE",
                       active: s.sensors.micActive,
                       activeColor: Theme.amber, k: m.k)
            StatusPill(label: "THERMAL",
                       value: s.sensors.thermalLabel,
                       active: s.sensors.thermal >= 2,
                       activeColor: Theme.danger, k: m.k)
            StatusPill(label: "POWER",
                       value: s.sensors.powerLabel,
                       active: s.sensors.isCharging,
                       activeColor: Theme.lime, k: m.k)

            if s.sensors.hasBattery {
                MeterRow(label: "CHARGE", value: "\(s.sensors.percent)%",
                         fraction: Double(s.sensors.percent) / 100,
                         accent: s.sensors.percent < 20 ? Theme.danger : Theme.lime,
                         k: m.k, labelWidth: 44)
                HStack(spacing: 8 * m.k) {
                    StatTile(label: "CYCLES", value: "\(s.sensors.cycleCount)",
                             accent: Theme.textDim, k: m.k)
                    StatTile(label: "VOLTS", value: String(format: "%.2f", s.sensors.voltage),
                             accent: Theme.textDim, k: m.k)
                    StatTile(label: "AMPS", value: String(format: "%.2f", s.sensors.amperage),
                             accent: Theme.textDim, k: m.k)
                    if let mins = s.sensors.minutesRemaining {
                        StatTile(label: "REMAIN", value: "\(mins / 60)H\(mins % 60)M",
                                 accent: Theme.amber, k: m.k)
                    }
                }
            }
        }
    }

    // MARK: System stats

    private func systemPanel(_ m: Metrics) -> some View {
        panelBox(m) {
            SectionLabel(text: "SYSTEM", accent: accent.opacity(0.85),
                         trailing: "VOLUME /", k: m.k)

            MeterRow(label: "DISK", value: "\(Fmt.gb0(s.volTotal - s.volFree))/\(Fmt.gb0(s.volTotal))G",
                     fraction: s.volFraction, accent: Theme.cyan, k: m.k)
            if s.gpuAvailable && m.mode == .wide {
                MeterRow(label: "GPU", value: Fmt.pct(s.gpuUtil) + "%",
                         fraction: s.gpuUtil, accent: Theme.heat(s.gpuUtil), k: m.k)
            }

            HStack(spacing: 8 * m.k) {
                StatTile(label: "TASKS", value: "\(s.procCount)", accent: Theme.textBright, k: m.k)
                StatTile(label: "SWAP", value: Fmt.bytes(s.swapUsed), accent: Theme.amber, k: m.k)
                StatTile(label: "PAGE IN", value: Fmt.bytes(s.pageIns * 4096), accent: Theme.textDim, k: m.k)
                StatTile(label: "FREE", value: Fmt.gb0(s.volFree) + "G", accent: Theme.lime, k: m.k)
            }
            if m.mode == .dense {
                HStack(spacing: 8 * m.k) {
                    StatTile(label: "PAGE OUT", value: Fmt.bytes(s.pageOuts * 4096),
                             accent: Theme.textDim, k: m.k)
                    StatTile(label: "FAULTS", value: Fmt.bytes(s.faults), accent: Theme.textDim, k: m.k)
                    StatTile(label: "CACHED", value: Fmt.bytes(s.memCached), accent: Theme.lime, k: m.k)
                    StatTile(label: "CORES", value: "\(s.coreCount)", accent: Theme.textDim, k: m.k)
                }
            }
        }
    }

    // MARK: Footer

    private func footer(_ m: Metrics) -> some View {
        HStack(spacing: 6 * m.k) {
            Text("UPTIME")
                .font(Theme.mono(7.5 * m.k, .bold))
                .tracking(1.6)
                .foregroundStyle(Theme.textGhost)
            Text(Fmt.uptime(s.uptime))
                .font(Theme.mono(9 * m.k, .bold))
                .foregroundStyle(Theme.textDim)
            Rectangle().fill(Theme.rule).frame(height: 1)
            if cast.isOn {
                Text("CAST \(cast.clients)")
                    .font(Theme.mono(7.5 * m.k, .bold))
                    .tracking(1.4)
                    .foregroundStyle(cast.clients > 0 ? Theme.lime : Theme.cyan.opacity(0.7))
            }
            if s.sensors.lowPower {
                Text("LOW POWER")
                    .font(Theme.mono(7.5 * m.k, .bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.amber)
            }
            Text(s.isStressed ? "SYS STRAIN" : "ALL SYSTEMS")
                .font(Theme.mono(7.5 * m.k, .bold))
                .tracking(1.4)
                .foregroundStyle(s.isStressed ? Theme.danger : Theme.lime.opacity(0.8))
                .glow(s.isStressed ? Theme.danger : Theme.lime, radius: 3, intensity: 0.45)
        }
    }
}
