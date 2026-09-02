import AppKit
import SwiftUI

// MARK: - Panel

/// Borderless floating HUD. Non-activating so clicking it never steals focus
/// from whatever you're actually working in, but still key-capable so it can
/// receive Escape and Command-Q.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape leaves full screen.
    override func cancelOperation(_ sender: Any?) {
        WindowManager.shared.exitFullScreen()
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "q" where cmd:
            NSApp.terminate(nil)
        case "f" where cmd:
            WindowManager.shared.toggleFullScreen()
        case "\u{1b}":
            WindowManager.shared.exitFullScreen()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: HUDPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        var size = NSSize(width: 360, height: 520)
        if let spec = ProcessInfo.processInfo.environment["NEOSTAT_SIZE"] {
            let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
        }

        panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Drag is driven from SwiftUI; NSHostingView swallows the events AppKit
        // would otherwise use for background dragging.
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = !Perf.noWinShadow
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: WindowManager.minWidth, height: WindowManager.minHeight)
        panel.maxSize = NSSize(width: 12000, height: 12000)

        // Real window blur behind the translucent HUD chrome.
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = Perf.noVibrancy ? .withinWindow : .behindWindow
        blur.state = (Perf.noBlur || Perf.noVibrancy) ? .inactive : .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: HUDView())
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)

        panel.contentView = blur

        WindowManager.shared.panel = panel
        WindowManager.shared.chrome = blur
        if ProcessInfo.processInfo.environment["NEOSTAT_SIZE"] == nil {
            WindowManager.shared.restoreSavedFrame(default: size)
        } else {
            panel.setFrame(NSRect(origin: NSPoint(x: 60, y: 60), size: size), display: false)
        }
        WindowManager.shared.installDragMonitor()
        WindowManager.shared.observeOcclusion()

        panel.orderFrontRegardless()
        panel.makeKey()

        // Resume broadcasting if it was on when the app last quit.
        Broadcast.shared.restore()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}


// MARK: - Offscreen self-test

/// Renders the HUD at several sizes into PNGs without touching the screen.
/// `cacheDisplay` draws the view hierarchy itself, so no Screen Recording
/// permission is involved. Window blur is a compositor effect and won't appear.
func runSelfTest(outDir: String) -> Never {
    let sizes: [(String, NSSize)] = [
        ("min",       NSSize(width: 322, height: 468)),
        ("compact",   NSSize(width: 380, height: 760)),
        ("wideshort", NSSize(width: 900, height: 640)),
        ("widetall",  NSSize(width: 900, height: 1000)),
        ("dense",     NSSize(width: 1600, height: 1000)),
        ("laptopfs",  NSSize(width: 1512, height: 982)),
    ]

    var hosts: [(String, NSView)] = []
    var windows: [NSWindow] = []

    for (name, size) in sizes {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HUDView())
        host.frame = NSRect(origin: .zero, size: size)
        w.contentView = host
        w.orderBack(nil)
        windows.append(w)
        hosts.append((name, host))
    }

    // Let the monitor take samples and the boot sequence finish.
    let deadline = Date().addingTimeInterval(5.0)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    for (name, host) in hosts {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write("no rep for \(name)\n".data(using: .utf8)!)
            continue
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
            try? data.write(to: url)
            print("wrote \(url.path) \(Int(host.bounds.width))x\(Int(host.bounds.height))")
        }
    }
    exit(0)
}


// MARK: - Sampling benchmark

func runBench() -> Never {
    func time(_ name: String, _ iterations: Int, _ body: () -> Void) {
        body()  // warm up
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations { body() }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) / Double(iterations) * 1000
        print(String(format: "  %-22@ %7.3f ms", name as NSString, ms))
    }

    print("per-call cost:")
    time("cpuTicks", 50) { _ = SystemMonitor.cpuTicks() }
    time("memory", 50) { _ = SystemMonitor.memory() }
    time("swap", 50) { _ = SystemMonitor.swap() }
    time("networkBytes", 50) { _ = SystemMonitor.networkBytes() }
    time("diskBytes", 20) { _ = SystemMonitor.diskBytes() }
    time("GPUProbe", 20) { _ = GPUProbe.utilization() }
    time("volume", 50) { _ = SystemMonitor.volume() }
    time("uptime", 50) { _ = SystemMonitor.uptime() }

    let probe = ProcessProbe()
    time("ProcessProbe.sample", 5) { _ = probe.sample(limit: 10) }
    time("SensorProbe.sample", 5) { _ = SensorProbe.sample() }
    exit(0)
}

// MARK: - Bootstrap

let app = NSApplication.shared

if CommandLine.arguments.contains("--bench") {
    app.setActivationPolicy(.accessory)
    runBench()
}

if let idx = CommandLine.arguments.firstIndex(of: "--selftest"),
   idx + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.accessory)
    runSelfTest(outDir: CommandLine.arguments[idx + 1])
}

let delegate = AppDelegate()
app.delegate = delegate
// Accessory: lives in the floating layer with no Dock icon and no menu bar.
app.setActivationPolicy(.accessory)
app.run()
