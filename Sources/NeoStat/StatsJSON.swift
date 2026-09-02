import Foundation
import AppKit

/// Wire format for the phone/tablet dashboard.
///
/// Hand-built rather than Codable: `Snapshot` carries tuples and `Series`
/// values that don't encode for free, series get trimmed to what a phone
/// actually plots, and every float is rounded — full doubles tripled the
/// payload for digits no screen shows.
enum StatsJSON {
    /// Samples of history sent per trace. 60 fills a phone-width graph.
    private static let window = 60

    static func encode(_ s: Snapshot) -> Data {
        let payload: [String: Any] = [
            "t": s.tick,
            "host": s.hostName,
            "chip": Fmt.shortChip(s.chip),
            "up": Int(s.uptime),
            "stressed": s.isStressed,
            "clock": Int(Date().timeIntervalSince1970),

            "cpu": [
                "total": r(s.cpuTotal),
                "user": r(s.cpuUser),
                "sys": r(s.cpuSystem),
                "cores": s.coreCount,
                "eff": s.efficiencyCores,
                "load": [r2(s.loadAvg.0), r2(s.loadAvg.1), r2(s.loadAvg.2)],
                "peak": r(s.cpuSeries.peak),
                "per": s.cores.map { r($0.total) },
                "series": trim(s.cpuSeries),
            ],

            "gpu": [
                "available": s.gpuAvailable,
                "util": r(s.gpuUtil),
                "series": trim(s.gpuSeries),
            ],

            "mem": [
                "total": s.memTotal,
                "used": s.memUsed,
                "app": s.memApp,
                "wired": s.memWired,
                "compressed": s.memCompressed,
                "cached": s.memCached,
                "fraction": r(s.memFraction),
                "pressure": Int(s.pressureLevel),
                "pressureLabel": s.pressureLabel,
                "swapUsed": s.swapUsed,
                "swapTotal": s.swapTotal,
                "series": trim(s.memSeries),
            ],

            "net": [
                "rx": Int(s.netRx),
                "tx": Int(s.netTx),
                "rxSeries": trimRate(s.netRxSeries),
                "txSeries": trimRate(s.netTxSeries),
            ],

            "disk": [
                "read": Int(s.diskRead),
                "write": Int(s.diskWrite),
                "readSeries": trimRate(s.diskReadSeries),
                "writeSeries": trimRate(s.diskWriteSeries),
                "volTotal": s.volTotal,
                "volFree": s.volFree,
                "volFraction": r(s.volFraction),
            ],

            "proc": [
                "count": s.procCount,
                "cpu": s.topCPU.map(proc),
                "mem": s.topMem.map(proc),
            ],

            "sensors": [
                "hasBattery": s.sensors.hasBattery,
                "percent": s.sensors.percent,
                "charging": s.sensors.isCharging,
                "onAC": s.sensors.onAC,
                "cycles": s.sensors.cycleCount,
                "volts": r2(s.sensors.voltage),
                "amps": r2(s.sensors.amperage),
                "minutes": s.sensors.minutesRemaining ?? -1,
                "power": s.sensors.powerLabel,
                "camera": s.sensors.cameraActive,
                "mic": s.sensors.micActive,
                "micName": s.sensors.micName,
                "thermal": s.sensors.thermal,
                "thermalLabel": s.sensors.thermalLabel,
                "lowPower": s.sensors.lowPower,
            ],
        ]

        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    private static func proc(_ p: ProcInfo) -> [String: Any] {
        ["pid": Int(p.id), "name": p.name, "cpu": r2(p.cpu), "rss": p.rss]
    }

    /// Fixed point, not floats.
    ///
    /// JSONSerialization prints doubles at full precision — `0.149` goes out as
    /// `0.14899999999999999`, four times the bytes for digits no screen shows.
    /// Fractions therefore travel as permille integers and the page divides
    /// them back on arrival, which halves the packet.
    private static func r(_ v: Double) -> Int {
        Int((min(max(v, 0), 1) * 1000).rounded())
    }

    /// Hundredths, unclamped — amperage is signed and load average exceeds 1.
    private static func r2(_ v: Double) -> Int {
        Int((v * 100).rounded())
    }

    private static func trim(_ s: Series) -> [Int] {
        Array(s.values.suffix(window)).map(r)
    }

    /// Byte-rate traces keep whole bytes; a phone rescales them anyway.
    private static func trimRate(_ s: Series) -> [Int] {
        Array(s.values.suffix(window)).map { Int(max($0, 0)) }
    }
}

// MARK: - Watch feed

/// Plain text sized for an Apple Watch, fetched by a Shortcut.
///
/// watchOS has no browser, but Shortcuts' "Get Contents of URL" runs on the
/// watch itself, and a shortcut can sit on the watch face as a complication.
/// So the watch gets its own route: no markup, no JSON to parse, just lines
/// short enough for a 40mm screen.
enum WatchFeed {
    static func text(_ s: Snapshot) -> Data {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"

        var lines: [String] = []
        lines.append("NEOSTAT \(f.string(from: Date()))")
        lines.append("")
        lines.append("CPU \(pad(s.cpuTotal)) \(bar(s.cpuTotal))")
        lines.append("MEM \(pad(s.memFraction)) \(bar(s.memFraction))")
        if s.gpuAvailable {
            lines.append("GPU \(pad(s.gpuUtil)) \(bar(s.gpuUtil))")
        }
        lines.append("")
        lines.append("NET ↓\(tight(s.netRx)) ↑\(tight(s.netTx))")
        lines.append("DSK ↓\(tight(s.diskRead)) ↑\(tight(s.diskWrite))")

        if s.sensors.hasBattery {
            let charge = s.sensors.isCharging ? "⚡" : ""
            lines.append("BAT \(s.sensors.percent)%\(charge) · \(s.sensors.thermalLabel)")
        } else {
            lines.append("THERM \(s.sensors.thermalLabel)")
        }
        lines.append("UP \(Fmt.uptime(s.uptime))")

        if let top = s.topCPU.first, top.cpu > 5 {
            lines.append("")
            lines.append("TOP \(Fmt.clip(top.name, 12)) \(Int(top.cpu))%")
        }
        if s.isStressed { lines.append("⚠ SYSTEM STRAIN") }

        return Data(lines.joined(separator: "\n").utf8)
    }

    /// Fmt.rate spaces the unit off the number; a 40mm screen can't spare it.
    private static func tight(_ v: Double) -> String {
        Fmt.rate(v).replacingOccurrences(of: " ", with: "")
    }

    private static func pad(_ f: Double) -> String {
        let v = Fmt.pct(f) + "%"
        return v.count < 4 ? String(repeating: " ", count: 4 - v.count) + v : v
    }

    /// Six blocks — as wide as a 40mm watch fits beside a label.
    private static func bar(_ f: Double) -> String {
        let filled = Int((min(max(f, 0), 1) * 6).rounded())
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: 6 - filled)
    }
}

// MARK: - Home-screen icon

/// Drawn rather than shipped as a file: the app has no Resources bundle, and a
/// generated PNG keeps `swift build` the only build step.
enum AppIcon {
    nonisolated(unsafe) private static var cache: [Int: Data] = [:]

    /// Called only from the cast queue, which serializes the cache.
    static func png(size: Int) -> Data {
        if let hit = cache[size] { return hit }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return Data() }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let s = CGFloat(size)
        let rect = NSRect(x: 0, y: 0, width: s, height: s)
        NSColor(srgbRed: 0.024, green: 0.028, blue: 0.055, alpha: 1).setFill()
        rect.fill()

        // Scanlines, at the same 2px rhythm as the HUD.
        NSColor(srgbRed: 0, green: 0.898, blue: 1, alpha: 0.05).setFill()
        var y: CGFloat = 0
        while y < s {
            NSRect(x: 0, y: y, width: s, height: s / 90).fill()
            y += s / 45
        }

        let inset = s * 0.10
        let frame = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                 xRadius: s * 0.10, yRadius: s * 0.10)
        frame.lineWidth = s * 0.02
        NSColor(srgbRed: 0, green: 0.898, blue: 1, alpha: 0.55).setStroke()
        frame.stroke()

        let glyph = "N" as NSString
        let font = NSFont.monospacedSystemFont(ofSize: s * 0.46, weight: .black)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(srgbRed: 0.847, green: 0.949, blue: 1, alpha: 1),
        ]
        let sz = glyph.size(withAttributes: attrs)
        glyph.draw(at: NSPoint(x: (s - sz.width) / 2, y: (s - sz.height) / 2), withAttributes: attrs)

        NSGraphicsContext.restoreGraphicsState()

        let data = rep.representation(using: .png, properties: [:]) ?? Data()
        cache[size] = data
        return data
    }
}
