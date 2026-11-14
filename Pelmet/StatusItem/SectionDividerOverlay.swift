import AppKit
import PelmetCore
import PelmetEngine

/// Draws the group boundary without registering a status item or changing the user’s icon order.
@MainActor
final class SectionDividerOverlay {
    private var windows: [CGDirectDisplayID: NSPanel] = [:]
    private var frames: [CGDirectDisplayID: CGRect] = [:]
    private var reported: [CGDirectDisplayID: String] = [:]

    func hide() {
        if !frames.isEmpty { PelmetLog.log("divider: reveal ended or busy, hidden") }
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
            for window in windows.values { window.orderOut(nil) }
            return
        }
        draw()
    }

    /// `onScreen` stays optional: `drawnBarHeight` falls back to its own read
    /// when the window list is nil, and an empty array would read as a real
    /// list with no menu bar in it — every display "not visible" whenever the
    /// list call fails.
    private func draw() {
        let onScreen = ConcealGhostOverlay.onScreenWindows()
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
            // Live mode's cover only: an anchored reveal keeps a held bar
            // picture up for `AppTiming.anchoredBarCeiling` (a day), and those
            // are not live covers. Counting every cover meant the divider
            // never drew at all once Hidden was pinned.
            guard !ConcealGhostOverlay.liveCover(over: cocoaFrame) else {
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
                window.contentView = DividerView()
                windows[id] = window
            }
            window.setFrame(cocoaFrame, display: true)
            window.orderFrontRegardless()
            report(id, "shown at \(Int(frame.minX)),\(Int(frame.minY))")
        }
    }

    /// Log state changes only: a redraw that reaches the same verdict as the
    /// last one says nothing, so missing geometry, a cover and drawing each
    /// appear once per change.
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
