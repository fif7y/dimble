// GlassPanel.swift
// The surface Pelmet's floating panels share: a borderless, non-activating
// glass panel that hangs under the menu bar. Non-activating, so the app you
// were in stays in front. It draws no border of its own: the rounded glass
// is the edge, with the system shadow re-derived whenever the glass changes
// (an earlier panel's edge read as a heavy near-black ring that ignored the
// corners, and a shadow taken before the glass had its shape is the suspect).
//
// The window can be made as tall as the glass will ever get, with the glass
// in it pinned to the top (`setGlassHeight`): resizing the window itself
// waits on the window server, ~5–30ms a keystroke live (2026-10-04), and the
// glass inside it can change height without that.

import AppKit
import PelmetCore
import PelmetEngine
import QuartzCore

@MainActor
class GlassPanel: NSPanel {
    static let cornerRadius: CGFloat = 12
    /// The system's shadow follows the rounded glass once it is re-derived
    /// (see `setGlassHeight`). If a live look still shows a dark ring at the edge,
    /// this is the one switch: the glass reads fine without a shadow.
    static let usesSystemShadow = true
    static let gapBelowBar: CGFloat = 4
    static let edgeMargin: CGFloat = 8

    /// `content` fills the glass; it is the caller's to size and lay out.
    init(content: NSView, cornerRadius: CGFloat = GlassPanel.cornerRadius) {
        content.translatesAutoresizingMaskIntoConstraints = false
        let host: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            host = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(content)
            host = effect
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                content.topAnchor.constraint(equalTo: effect.topAnchor),
                content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
        }
        let clear = NSView(frame: .zero)
        // Nothing a SwiftUI layer draws past the glass may reach the window's
        // shadow: with a window taller than the glass it drew a hard ring 17pt
        // below the glass (harness screenshots, 2026-10-04).
        host.clipsToBounds = true
        host.frame = clear.bounds
        host.autoresizingMask = [.width, .minYMargin]
        clear.addSubview(host)
        glass = host
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = Self.usesSystemShadow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Its size is its content's: no edge resize, no drag of the surface.
        styleMask.remove(.resizable)
        isMovable = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = clear
    }

    /// The glass inside the window, as tall as `setGlassHeight` last said.
    private let glass: NSView

    var glassHeight: CGFloat { glass.frame.height }

    /// Clear room left of the glass, for `edgeAccessory` to reach past its
    /// edge. The window is this much wider than the glass.
    var leadingMargin: CGFloat = 0 {
        didSet { setGlassHeight(glass.frame.height) }
    }

    /// Laid over the glass's left edge, half in `leadingMargin`, as tall as
    /// the glass: the panel's column grip. Set once.
    var edgeAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let edgeAccessory { contentView?.addSubview(edgeAccessory) }
            layoutAccessory()
        }
    }

    /// Where the glass is on screen; below it the window is clear.
    var glassScreenFrame: NSRect {
        NSRect(x: frame.minX + leadingMargin, y: frame.maxY - glass.frame.height,
               width: frame.width - leadingMargin, height: glass.frame.height)
    }

    /// Move or resize the window, then re-derive the shadow from what is on
    /// screen.
    func place(_ frame: NSRect, display: Bool = true) {
        setFrame(frame, display: display)
        glass.frame.size.height = min(glass.frame.height, frame.height)
        layoutAccessory()
        invalidateShadow()
    }

    /// `place` and `setGlassHeight` together, the shadow derived once. A
    /// window already there with its glass at that height is left alone,
    /// unless it is hidden: the first placement of a show derives the shadow
    /// again.
    func place(_ frame: NSRect, glassHeight height: CGFloat, display: Bool = true) {
        guard !isVisible || self.frame != frame || glass.frame.height != min(height, frame.height) else { return }
        setFrame(frame, display: display)
        layoutGlass(height: height)
        invalidateShadow()
    }

    /// Change the glass's height inside the window, its top edge staying
    /// put; the window is not resized. Below the glass the window is clear.
    /// A fold steps this at 120Hz: the shadow is derived again once the
    /// glass has moved a point since it last was, a lag no one sees, and
    /// `place` always derives it.
    func setGlassHeight(_ height: CGFloat) {
        layoutGlass(height: height)
        guard abs(glass.frame.height - shadowHeight) >= 1 else { return }
        invalidateShadow()
    }

    /// The glass's height when the shadow was last derived.
    private var shadowHeight: CGFloat = -1

    override func invalidateShadow() {
        shadowHeight = glass.frame.height
        super.invalidateShadow()
    }

    private func layoutGlass(height: CGFloat) {
        let bounds = contentView?.bounds ?? .zero
        let height = min(height, bounds.height)
        glass.frame = NSRect(x: leadingMargin, y: bounds.height - height,
                             width: max(bounds.width - leadingMargin, 0), height: height)
        layoutAccessory()
    }

    private func layoutAccessory() {
        guard let edgeAccessory else { return }
        edgeAccessory.frame = NSRect(x: 0, y: glass.frame.minY, width: 2 * leadingMargin, height: glass.frame.height)
    }

    /// The bar's own height on `screen`: its window's when one is drawn
    /// (`BarBand.height`: a MacBook with an Island has a 45pt bar over a
    /// 40pt safe area, #156), else the visibleFrame band. Under a
    /// full-screen app it is the safe area, cut to the window's height
    /// when that is shorter, never raised to it. Off the main display the
    /// visibleFrame keeps no band, and a 30pt bar read as none and became
    /// 24 (externals, 2026-10-12): the window answers there too.
    static func barHeight(of screen: NSScreen) -> CGFloat {
        let drawn = drawnBarHeight(of: screen)
        let band = BarBand.height(
            safe: screen.safeAreaInsets.top, visible: screen.frame.maxY - screen.visibleFrame.maxY, window: drawn)
        return band > 0 ? band : drawn ?? 24
    }

    /// The bar across `screen`, at `barHeight`.
    static func barBand(of screen: NSScreen) -> NSRect {
        let bar = barHeight(of: screen)
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - bar, width: screen.frame.width, height: bar)
    }

    /// The bar's window on each display, as read: kept while the display's
    /// bounds stay the same (a read walks every window on screen; another
    /// screens observer can run before this one clears it), a miss retried
    /// after a second.
    private static var drawnBarHeights: [CGDirectDisplayID: (height: CGFloat?, bounds: CGRect, readAt: CFTimeInterval)] = [:]
    private static var screensObserver: NSObjectProtocol?

    /// The Window Server's bar window (layer 24) whose top is the display's,
    /// nil on a display with no bar drawn (Displays have separate Spaces
    /// off, an app full screen). `fresh` reads it again: a full-screen app
    /// takes the bar away with no screens change. `windows`: the on-screen
    /// list already read, for a caller asking about every display at once.
    static func drawnBarHeight(of screen: NSScreen, fresh: Bool = false, in windows: [[String: Any]]? = nil) -> CGFloat? {
        guard let id = screen.directDisplayID else { return nil }
        let now = CACurrentMediaTime()
        let display = CGDisplayBounds(id)
        let kept = drawnBarHeights[id]
        if !fresh, let kept, kept.bounds == display, kept.height != nil || now - kept.readAt < 1 { return kept.height }
        if screensObserver == nil {
            screensObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { GlassPanel.drawnBarHeights = [:] }
            }
        }
        var height: CGFloat?
        if let list = windows ?? ConcealGhostOverlay.onScreenWindows() {
            let barLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
            for w in list where (w[kCGWindowLayer as String] as? Int) == barLevel && (w[kCGWindowOwnerName as String] as? String) == "Window Server" {
                // A bar is 20pt at the least: a thinner strip there is not one.
                guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = b["X"], let y = b["Y"], let h = b["Height"], h >= 20, h < 100,
                      abs(y - display.minY) < 1, x >= display.minX - 1, x < display.maxX
                else { continue }
                height = h
                break
            }
        }
        // A fresh miss answers its caller only: kept for a second, it left
        // a strip filmed then uncut while its empty-bar picture was cut.
        let stored = height != nil || !fresh || kept?.height == nil || kept?.bounds != display
        if stored { drawnBarHeights[id] = (height, display, now) }
        if stored, kept == nil || height != kept?.height {
            PelmetLog.log("glass: display \(id) bar \(height.map { "\(Int($0))pt from its window" } ?? "window not found, 24pt")")
        }
        return height
    }

    /// Top edge of a panel hung under the bar on `screen` (Cocoa y).
    static func topUnderBar(of screen: NSScreen) -> CGFloat {
        screen.frame.maxY - barHeight(of: screen) - gapBelowBar
    }
}

/// A glass panel that can take keyboard focus (a text field in it types)
/// without activating the app or becoming its main window.
final class KeyableGlassPanel: GlassPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
