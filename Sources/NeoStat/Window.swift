import AppKit
import SwiftUI
import Combine
import CoreGraphics

/// Owns the panel's geometry.
///
/// Dragging is handed to AppKit's `performDrag(with:)` rather than being driven
/// from a SwiftUI `DragGesture`. A gesture reports translation in a coordinate
/// space that belongs to the window, so moving the window moves the gesture's
/// own reference frame underneath it — the result is a feedback loop that reads
/// as jitter. `performDrag` runs in the window server: the content is not
/// re-rendered at all while the window moves.
final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published var isFullScreen = false
    /// True only for the duration of a drag; suppresses sampling and overlays.
    @Published var isDragging = false
    /// False when the window is hidden or fully covered — nothing needs updating.
    @Published var isVisible = true

    weak var panel: NSPanel?
    weak var chrome: NSVisualEffectView?

    /// Regions that must keep their own click handling (buttons, resize grip),
    /// in SwiftUI's top-left coordinate space.
    var noDragRects: [CGRect] = []

    static let minWidth: CGFloat = 300
    static let minHeight: CGFloat = 400
    private static let autosaveName = "NeoStatHUD"

    private var restoreFrame: NSRect?
    private var resizeFrame: NSRect?
    private var monitor: Any?
    private var occlusionObserver: Any?

    /// Stops sampling and decorative motion when the HUD is not actually visible.
    func observeOcclusion() {
        guard occlusionObserver == nil, let panel else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, let p = self.panel else { return }
            let vis = p.occlusionState.contains(.visible)
            self.isVisible = vis
            if Perf.countRenders {
                FileHandle.standardError.write("occlusion: visible=\(vis)\n".data(using: .utf8)!)
            }
        }
    }

    // MARK: Native drag

    /// Installed once at launch. A local monitor sees the mouse-down before the
    /// hosting view swallows it, which is what blocked window dragging before.
    func installDragMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  let panel = self.panel,
                  event.window === panel,
                  !self.isFullScreen,
                  self.isDraggablePoint(event.locationInWindow, in: panel)
            else { return event }

            // The monitor consumes the mouse-down, so focus the panel here or
            // it never becomes key and Escape / Command-Q stop working.
            panel.makeKey()

            if event.clickCount == 2 {
                self.toggleFullScreen()
                return nil
            }
            self.beginNativeDrag(event, panel)
            return nil   // consumed
        }
    }

    private func isDraggablePoint(_ pointInWindow: NSPoint, in panel: NSPanel) -> Bool {
        // AppKit's origin is bottom-left; SwiftUI reports rects from top-left.
        let flipped = CGPoint(x: pointInWindow.x,
                              y: panel.frame.height - pointInWindow.y)
        return !noDragRects.contains { $0.insetBy(dx: -2, dy: -2).contains(flipped) }
    }

    private func beginNativeDrag(_ event: NSEvent, _ panel: NSPanel) {
        // A non-opaque window recomputes its shadow from the alpha channel on
        // every move, which is the single most expensive part of dragging.
        let hadShadow = panel.hasShadow
        panel.hasShadow = false
        chrome?.state = .inactive
        isDragging = true

        panel.performDrag(with: event)   // modal until mouse-up

        isDragging = false
        chrome?.state = .active
        panel.hasShadow = hadShadow
        panel.invalidateShadow()
        persist()
    }

    // MARK: Resize (bottom-right grip)

    func resizeChanged(_ translation: CGSize) {
        guard !isFullScreen, let p = panel else { return }
        if resizeFrame == nil { resizeFrame = p.frame }
        guard let f = resizeFrame else { return }

        // Integral sizes avoid subpixel thrash while dragging the grip.
        let w = max(Self.minWidth, (f.width + translation.width).rounded())
        let h = max(Self.minHeight, (f.height + translation.height).rounded())
        let newFrame = NSRect(x: f.minX, y: f.maxY - h, width: w, height: h)
        guard newFrame != p.frame else { return }
        p.setFrame(newFrame, display: true)
    }

    func resizeEnded() {
        resizeFrame = nil
        persist()
    }

    // MARK: Full screen

    func toggleFullScreen() {
        isFullScreen ? exitFullScreen() : enterFullScreen()
    }

    func enterFullScreen() {
        guard !isFullScreen, let p = panel else { return }
        guard let screen = p.screen ?? NSScreen.main else { return }
        restoreFrame = p.frame
        // Shielding level draws above the menu bar and Dock for true edge-to-edge.
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        p.setFrame(screen.frame, display: true, animate: true)
        chrome?.layer?.cornerRadius = 0
        isFullScreen = true
    }

    func exitFullScreen() {
        guard isFullScreen, let p = panel else { return }
        p.level = .floating
        if let f = restoreFrame {
            p.setFrame(f, display: true, animate: true)
        }
        chrome?.layer?.cornerRadius = 12
        isFullScreen = false
        persist()
    }

    private func persist() {
        guard !isFullScreen else { return }
        panel?.saveFrame(usingName: Self.autosaveName)
    }

    func restoreSavedFrame(default size: NSSize) {
        guard let p = panel else { return }
        p.setFrameUsingName(Self.autosaveName)
        if p.frame.width < Self.minWidth || p.frame.height < Self.minHeight {
            var origin = NSPoint(x: 100, y: 100)
            if let vf = (p.screen ?? NSScreen.main)?.visibleFrame {
                origin = NSPoint(x: vf.maxX - size.width - 24,
                                 y: vf.maxY - size.height - 24)
            }
            p.setFrame(NSRect(origin: origin, size: size), display: false)
        }
    }
}

// MARK: - No-drag regions

struct NoDragKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Marks a region as click-through-to-SwiftUI, so window dragging skips it.
    func noDrag() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: NoDragKey.self,
                                       value: [geo.frame(in: .named(HUDSpace.name))])
            }
        )
    }
}

enum HUDSpace { static let name = "neostat.hud" }
