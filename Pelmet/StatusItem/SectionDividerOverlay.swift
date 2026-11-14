import AppKit
import PelmetCore
import PelmetEngine

/// Draws the group boundary without registering a status item or changing the user’s icon order.
@MainActor
final class SectionDividerOverlay {
    private var windows: [CGDirectDisplayID: NSPanel] = [:]
    private var frames: [CGDirectDisplayID: CGRect] = [:]
    private var visibilityTimer: Timer?
    private var reported: [CGDirectDisplayID: String] = [:]

    func hide() {
        if !frames.isEmpty { PelmetLog.log("divider: reveal ended or busy, hidden") }
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        frames.removeAll()
        reported.removeAll()
        for window in windows.values { window.orderOut(nil) }
    }

    func update(model: SectionModel, copies: [ItemID: [CGRect]]) {
        frames.removeAll()
        for screen in NSScreen.screens {
            guard let id = screen.directDisplayID else { continue }
            let display = CGDisplayBounds(id)
            let items = copies.compactMap { key, copies -> (section: PelmetCore.Section, frame: CGRect)? in
                guard let frame = MenuBarGeometry.copy(onDisplay: display, among: copies) else { return nil }
                return (model.section(of: key), frame)
            }
            frames[id] = MenuBarGeometry.alwaysHiddenDivider(items: items)
            if frames[id] == nil {
                report(id, "no boundary (\(items.filter { $0.section == .alwaysHidden }.count) always-hidden, \(items.count) frames)")
            }
        }
        guard !frames.isEmpty else {
            visibilityTimer?.invalidate()
            visibilityTimer = nil
            for window in windows.values { window.orderOut(nil) }
            return
        }
        draw()
        // Auto-hide and full-screen changes may not update icon snapshots; poll only while a divider is active.
        if visibilityTimer == nil {
            visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.draw() }
            }
        }
    }

    private func draw() {
        let onScreen = ConcealGhostOverlay.onScreenWindows() ?? []
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        for (id, window) in windows where frames[id] == nil { window.orderOut(nil) }
        for (id, frame) in frames {
            let cocoaFrame = NSRect(x: frame.minX, y: primaryTop - frame.maxY,
                                    width: frame.width, height: frame.height)
            guard let screen = NSScreen.screens.first(where: { $0.directDisplayID == id }),
                  GlassPanel.drawnBarHeight(of: screen, fresh: true, in: onScreen) != nil else {
                report(id, "menu bar not visible")
                windows[id]?.orderOut(nil)
                continue
            }
            guard !ConcealGhostOverlay.barCover(over: cocoaFrame) else {
                report(id, "bar covered")
                windows[id]?.orderOut(nil)
                continue
            }
            let window: NSPanel
            if let existing = windows[id] {
                window = existing
            } else {
                window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.ignoresMouseEvents = true
                window.hidesOnDeactivate = false
                window.level = .statusBar
                window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
                window.animationBehavior = .none
                window.sharingType = .none
                window.contentView = DividerView()
                windows[id] = window
            }
            window.setFrame(cocoaFrame, display: true)
            window.orderFrontRegardless()
            report(id, "shown at \(Int(frame.minX)),\(Int(frame.minY))")
        }
    }

    /// Log state changes only, distinguishing missing geometry, covers and drawing without polling noise.
    private func report(_ display: CGDirectDisplayID, _ state: String) {
        guard reported[display] != state else { return }
        reported[display] = state
        PelmetLog.log("divider: display \(display) \(state)")
    }

    private final class DividerView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            // Displays can have different wallpaper brightness; light and dark edges remain visible on either.
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSRect(x: 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}
