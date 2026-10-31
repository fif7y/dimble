// ConcealGhostOverlay.swift
// Snapshot covers floated over the bar. The agent animates every swap on
// its own (a slide-in on reveal, a fade in place on conceal — frame-burst
// 2026-09-08, 27.0 b8) and offers no way to turn that off, so Pelmet's
// styles are pictures animated OVER it: an empty-bar capture hides the
// agent's motion, and a picture of the icons (opaque, or cut out against
// the empty bar so it can move without smearing the wallpaper) performs the
// style's own move — see `AnimationRecipe` in TransitionCoordinator. Without
// a usable capture a style falls back to the agent's animation.

import AppKit
import PelmetEngine
import QuartzCore
import ScreenCaptureKit

/// Explicit Core Animation alpha fade. On macOS 27, `animator().alphaValue`
/// under NSAnimationContext completes almost immediately for windows AND
/// views (verified with presentation sampling, 2026-08-20) — the fade reads
/// as a pop. Only an explicit CABasicAnimation composites fractional alpha
/// over the full duration.
@MainActor
enum AlphaFade {
    static func run(
        _ view: NSView,
        to target: CGFloat,
        duration: CFTimeInterval,
        controlPoints points: (Float, Float, Float, Float),
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        view.wantsLayer = true
        guard let layer = view.layer else { completion?(); return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        if let completion {
            CATransaction.setCompletionBlock {
                Task { @MainActor in completion() }
            }
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = Float(target)
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(
            controlPoints: points.0, points.1, points.2, points.3
        )
        layer.add(anim, forKey: "pelmetAlphaFade")
        layer.opacity = Float(target)
        CATransaction.commit()
    }
}

@MainActor
/// A held bar's window: the clicks on the covered run are the bar's (#88).
private final class HeldBarPanel: NSPanel {
    /// Live mode: takes every click on the picture; the mirror's
    /// forwards it to the real pill.
    var clickHook: ((NSPoint) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let clickHook {
                clickHook(convertPoint(toScreen: event.locationInWindow))
                return
            }
            ConcealGhostOverlay.onHeldBarClick?(screen?.directDisplayID, event.clickCount)
        case .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            break
        default:
            super.sendEvent(event)
        }
    }
}

final class ConcealGhostOverlay {
    /// A click on a held bar's picture, with its display and click count:
    /// an empty-bar click there, so it does what one would (AppState).
    static var onHeldBarClick: ((CGDirectDisplayID?, Int) -> Void)?

    /// True while a reveal cover is up — SeparatorManager and ExtrasManager
    /// skip their per-item ghosts under it (a fading copy showing through
    /// would double-expose). Count-tracked: with back-to-back reveals, an
    /// OLDER cover's fade completion must not clear the flag while a newer
    /// cover is still up.
    static var stripActive: Bool { activeStripCount > 0 }
    private static var activeStripCount = 0

    /// One cover per display: the assertion swaps EVERY display's bar at
    /// once, so each bar gets its own strip. Forwarding wrapper so callers
    /// keep the single-cover call shape.
    struct GhostSet {
        fileprivate let overlays: [ConcealGhostOverlay]
        /// Live mode: the covers, to hang a mirror in each.
        var members: [ConcealGhostOverlay] { overlays }
        /// The covers' ids as they read in the `ghost:` lines, "#3 #4".
        var ids: String { overlays.map { "#\($0.id)" }.joined(separator: " ") }
        /// Still on screen: not dismissed, faded or timed out.
        var isUp: Bool { overlays.contains { !$0.finished } }
        func dismiss() { for overlay in overlays { overlay.dismiss() } }
        /// Keeps the safety fade at least `seconds` from now.
        func keepUp(for seconds: TimeInterval) { for overlay in overlays { overlay.keepUp(for: seconds) } }
        /// A held bar takes clicks; `true` lets them reach the bar beneath.
        func passClicks(_ through: Bool) { for overlay in overlays { overlay.passClicks(through) } }
        func fadeOut(duration: CFTimeInterval = ConcealGhostOverlay.dismissDuration, slide: Bool = false) {
            for overlay in overlays { overlay.fadeOut(duration: duration, slide: slide) }
        }
        /// Perform a recipe move: `entering` runs it from the offset/faded
        /// state to rest, otherwise from rest away. A `.pop` is a no-op
        /// (the picture is simply there, or simply lifted by the caller).
        func animate(_ move: AnimationRecipe.Move, entering: Bool) {
            for overlay in overlays { overlay.animate(move, entering: entering) }
        }
        /// Reveal the pictures from their right end leftwards, the way
        /// Notification Center's panel slides in under the bar (#51).
        func wipeInFromRight(insets: [CGFloat], frame: CFTimeInterval, delay: CFTimeInterval, edge: CGFloat) {
            for overlay in overlays { overlay.wipeInFromRight(insets: insets, frame: frame, delay: delay, edge: edge) }
        }
        /// Darken the pictures the way Notification Center's open panel
        /// darkens the bar through the glass (measured 2026-09-22: ×0.965
        /// at the top row to ×0.89 at the bottom).
        func addPanelShade() {
            for overlay in overlays { overlay.addPanelShade() }
        }
    }

    /// SCShareableContent lookup is the slow part (can be 100ms+) — cache the
    /// display handles so repeat conceals only pay for the captures.
    /// Invalidated on display reconfiguration: a stale SCDisplay makes every
    /// capture fail (no hide animation) or capture wrong geometry.
    private static var cachedDisplays: [CGDirectDisplayID: SCDisplay] = [:]
    private static var reconfigureObserver: NSObjectProtocol?

    static func prewarmDisplay() {
        if reconfigureObserver == nil {
            reconfigureObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    cachedDisplays = [:]
                    _ = await scDisplay(for: CGMainDisplayID())
                }
            }
        }
        Task { _ = await scDisplay(for: CGMainDisplayID()) }
    }

    private static func scDisplay(for id: CGDirectDisplayID) async -> SCDisplay? {
        if let cached = cachedDisplays[id] { return cached }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        for display in content.displays {
            cachedDisplays[display.displayID] = display
        }
        return cachedDisplays[id]
    }

    /// Other processes' surfaces drawn IN the bar over `rect` (CG global,
    /// top-left origin): at or above the bar's own level, taller than the
    /// band, reaching its top half. Never a status item (band-height), never
    /// the bar itself, never the Dock's layer-20 full-screen backstop
    /// (below the bar), never a panel whose top edge merely grazes the
    /// band's last rows.
    static func foreignBandWindows(
        intersecting rect: CGRect, bandHeight: CGFloat,
        in list: [[String: Any]]? = nil
    ) -> [(id: CGWindowID, owner: String)] {
        guard let list = list ?? onScreenWindows() else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let barLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = w[kCGWindowLayer as String] as? Int, layer >= barLevel,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  CGRect(x: x, y: y, width: width, height: height).intersects(rect)
            else { return nil }
            // Pelmet's own windows are the covers, except a menu: the
            // status item's context menu hangs into the band's last rows
            // while it fades out, and a picture taken at that conceal
            // replayed its top edge on the next hover reveal (#40).
            if pid == me {
                return layer >= menuLevel ? (id, "Pelmet menu") : nil
            }
            // Its top anywhere above the band's last row: Snib's panel
            // hangs 2pt into the bar (y 37 of 39), and a picture filmed
            // with it carried its top edge as a line under the tile.
            guard height > bandHeight + 1, y < rect.minY + bandHeight - 0.5 else { return nil }
            return (id, w[kCGWindowOwnerName as String] as? String ?? "pid \(pid)")
        }
    }

    /// The window server's on-screen list, fetched once per capture set:
    /// every display's band is filtered from the same list.
    static func onScreenWindows() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]
    }

    /// What shows through the glass behind `rect` (CG global, top-left):
    /// every other process's window below the bar's level whose bounds
    /// come within `backdropReach` of the band, on any display, as
    /// `[id, x, y, w, h]` runs sorted by id. Two equal signatures = the
    /// same backdrop; a moved, resized, raised or closed window changes
    /// it, and a picture of the bar taken under the old one is stale (#33:
    /// a Finder window's top edge slid in with the bar).
    /// `primaryOnly`: the primary display's band alone (the clock blink's
    /// under-panel picture is only ever shown there, and window traffic
    /// near the other bars invalidated it on every other click).
    static func backdropSignature(of rect: CGRect?, in list: [[String: Any]]? = nil, primaryOnly: Bool = false) -> [Int] {
        guard let rect, rect.width > 8, let list = list ?? onScreenWindows(),
              let primary = NSScreen.screens.first else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let notificationCenter = ClockClickRelay.notificationCenterPID()
        let barLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let zones: [CGRect] = (primaryOnly ? [primary] : NSScreen.screens).compactMap { screen in
            guard let displayID = screen.directDisplayID else { return nil }
            let bounds = CGDisplayBounds(displayID)
            let shift = screen.frame.maxX - primary.frame.maxX
            let band = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY, rect.maxY)
            return CGRect(
                x: rect.minX + shift - backdropReach, y: bounds.minY,
                width: rect.width + 2 * backdropReach, height: band + backdropReach)
        }
        var runs: [(CGWindowID, [Int])] = []
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = w[kCGWindowLayer as String] as? Int, layer < barLevel,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"]
            else { continue }
            // Notification Center is not a backdrop: its panel's state is
            // tracked on its own (`revealCoverUnderPanel`, the clock relay),
            // its windows linger in this list ~0.6s past the panel's exit,
            // its desktop widgets hide while the panel is open, and the
            // Dock raises a display-sized backstop under it. In the
            // signature they dropped the idle picture on every open and
            // again a second after every close (#51, 2026-09-22).
            // By pid, not name: the owner name is localized ("알림 센터").
            if ClockClickRelay.isNotificationCenterWindow(w, pid: notificationCenter) { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Dock", width >= 1000, height >= 700 { continue }
            let frame = CGRect(x: x, y: y, width: width, height: height)
            guard zones.contains(where: { $0.intersects(frame) }) else { continue }
            runs.append((id, [Int(id), Int(x), Int(y), Int(width), Int(height)]))
        }
        return runs.sorted { $0.0 < $1.0 }.flatMap(\.1)
    }
    /// What the bar's glass shows besides windows: the wallpaper behind each
    /// screen and the appearance. Two ints appended to the window
    /// signature, so a new wallpaper or a light/dark flip drops the
    /// pictures the way a moved window does (Gab, 2026-09-22: the blink
    /// cover showed the previous wallpaper for a quarter of an hour once
    /// it stopped capturing live, PR #50).
    static let surfaceSignatureCount = 2
    /// The wallpaper store's index is rewritten on every change, including
    /// the ones `desktopImageURL` misses: picking another variant of the
    /// same dynamic wallpaper keeps the path (Gab, 2026-09-22 14:21: the
    /// store changed, the URL did not, and the parked picture of the old
    /// wallpaper was restored a second later).
    private static let wallpaperStoreIndex = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist").path
    static func surfaceSignature() -> [Int] {
        var hasher = Hasher()
        for screen in NSScreen.screens {
            hasher.combine(NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? "")
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: wallpaperStoreIndex))?[.modificationDate] as? Date
        hasher.combine(modified?.timeIntervalSinceReferenceDate ?? 0)
        return [NSApp.effectiveAppearance.name.rawValue.hashValue, hasher.finalize()]
    }

    /// Mean luminance of the picture's columns over `primaryX` (debug: is a
    /// picture of the bar under Notification Center's panel darker?).
    static func meanLuma(_ snap: BarSnapshot, primaryX: ClosedRange<CGFloat>) -> Double {
        let scale = CGFloat(snap.image.width) / snap.windowFrame.width
        let x0 = max(0, Int((primaryX.lowerBound - snap.windowFrame.minX) * scale))
        let x1 = min(snap.image.width, Int((primaryX.upperBound - snap.windowFrame.minX) * scale))
        guard x1 > x0, let data = snap.image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return -1 }
        let bpr = snap.image.bytesPerRow, bpp = snap.image.bitsPerPixel / 8
        var sum = 0.0, n = 0.0
        for y in stride(from: 0, to: snap.image.height, by: 4) {
            for x in stride(from: x0, to: x1, by: 4) {
                let o = y * bpr + x * bpp
                sum += (Double(ptr[o]) + Double(ptr[o + 1]) + Double(ptr[o + 2])) / 3; n += 1
            }
        }
        return n > 0 ? sum / n : -1
    }

    /// Who moved between two signatures, by owner, for the log (#49: the
    /// changes were almost all one window in and out of the zone, and the
    /// count alone never said which).
    static func backdropMovers(from old: [Int], to new: [Int], in list: [[String: Any]]?) -> String {
        func runs(_ sig: [Int]) -> Set<[Int]> { Set(stride(from: 0, to: sig.count, by: 5).map { Array(sig[$0..<min($0 + 5, sig.count)]) }) }
        if old.suffix(surfaceSignatureCount) != new.suffix(surfaceSignatureCount) { return "wallpaper or appearance" }
        let changed = runs(old.dropLast(surfaceSignatureCount)).symmetricDifference(runs(new.dropLast(surfaceSignatureCount))).compactMap(\.first)
        var names: [String] = []
        for id in Set(changed).sorted() {
            let owner = list?.first { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == id }?[kCGWindowOwnerName as String] as? String
            let name = owner ?? "closed"
            if !names.contains(name) { names.append(name) }
        }
        return names.prefix(4).joined(separator: ", ") + (names.count > 4 ? ", …" : "")
    }
    /// How far below the band a window still tints it: the glass blur
    /// and a window's shadow both reach a few dozen points.
    static let backdropReach: CGFloat = 48

    /// WindowServer's own bar window, every icon's glyph drawn in it:
    /// "Menubar" at the main menu level with no app behind it — an owner
    /// with an empty bundle id on 27.2, not a nil one (live, 2026-10-19).
    static func isSystemBar(_ window: SCWindow) -> Bool {
        window.title == "Menubar" && (window.owningApplication?.bundleIdentifier ?? "").isEmpty
    }

    private let window: NSWindow
    /// The foreign surface this cover slipped in beneath, if any.
    private var beneathID: CGWindowID?
    private let imageView: NSImageView
    /// A held bar's stationary twin (`watchMissionControl`).
    private var twin: NSWindow?
    /// The twin's picture before `shapeTwin` cuts it down to the icons.
    private var twinPicture: CGImage?
    /// `iconLayout` when the twin was cut; nil while it is whole.
    private var twinLayout: [Int]?
    private var twinShapeGeneration = 0
    private var finished = false
    private var stoodDown = false
    /// Counted in `stripActive`: a transition's cover. A held bar
    /// (`holdsBar`) stays up for a whole reveal and is not one.
    private let countsAsStrip: Bool
    /// When the safety fade is due. Fixed at `begin` unless a caller that
    /// knows better (a picture pass running follow-up rounds) pushes it out.
    private var safetyEnd = Date()
    /// One per cover, in the `ghost:` log lines, so a cover that outlived
    /// its blink can be matched to the line that raised it (#52).
    private static var nextID = 0
    let id: Int

    /// A captured strip image ready to float — pre-captured at conceal settle
    /// so the reveal path pays zero capture latency.
    struct BarSnapshot: @unchecked Sendable {
        let image: CGImage
        /// Cocoa bottom-left global — where this display's cover floats.
        let windowFrame: NSRect
        let takenAt: Date

        /// The display this picture floats on.
        @MainActor var display: CGDirectDisplayID? {
            NSScreen.screens.first { NSMouseInRect(NSPoint(x: windowFrame.midX, y: windowFrame.midY), $0.frame, false) }?
                .directDisplayID
        }
    }

    /// Capture the strip on every display. `rect` is the primary-band strip
    /// in AX global top-left coordinates (the engine's canonical frames);
    /// other bars mirror the same items against their own trailing edge, so
    /// the rect translates right-anchored (the notch only eats the leading
    /// side). Empty result → callers run uncovered, never blocked.
    /// Without Screen Recording every reveal runs uncovered (the agent's
    /// slide-in shows). Contextual: the system prompt fires the first time a
    /// cover is actually wanted (once per launch, see ScreenRecordingAccess);
    /// the General tab's Permissions card carries the row for anyone who
    /// dismissed it (issue #6).
    /// Points the capture extends past the requested rect on each side so
    /// the picture's background is continuous with the bar around it.
    static let capturePadding: CGFloat = 6

    /// When Pelmet last took a picture. Every capture lights the system's
    /// screen-capture indicator at the bar's right end, which shifts the
    /// whole cluster left ~3pt and stays ~3s past the last capture
    /// (measured 3.0–3.2s, `screencapture` and a one-frame SCStream alike,
    /// 2026-09-16). While it is lit the bar is already in its shifted
    /// place, so a picture taken now needs no retake.
    private(set) static var lastCaptureAt: Date?
    static var captureIndicatorLit: Bool {
        lastCaptureAt.map { Date().timeIntervalSince($0) < AppTiming.captureIndicatorHold } ?? false
    }

    /// When the status item's context menu last closed. NSMenu fades out
    /// for a beat after the click that dismisses it, still on screen for
    /// the window list, and a picture taken inside that beat carried the
    /// menu's top rows into the next hover reveal (#40). Captures wait it
    /// out; `foreignBandWindows` leaves the menu out should one overlap.
    static var menuClosedAt: Date?
    static let menuFadeHold: TimeInterval = 0.5

    /// Pelmet's own on-screen windows, for `snapshotSet(ownWindows:)`: a
    /// pass films several frames under one cover and looks them up once,
    /// not once per display per frame (10-40ms each, review EFF-1).
    static func ownWindows() async -> [SCWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content?.windows.filter { $0.owningApplication?.processID == me } ?? []
    }

    /// Said once per display and heights, not per film.
    private static var lastBandClampLine = ""

    /// `excludingOwnWindows`: leave Pelmet's own windows out, so a picture
    /// taken under a cover shows the real bar beneath it (the panel's
    /// picture pass); `ownWindows` names them, looked up here when nil.
    /// `primaryOnly`: the primary display's band alone, all a pass cuts
    /// from (review EFF-2).
    /// `displays`: only these displays' bars (nil: every one).
    /// `bare`: the bar as it is with no icon on it, at any time — the
    /// WindowServer's Menubar window (the items and the menus) and Pelmet's
    /// own windows left out. The bar is clear glass: what is left matches
    /// the empty bar pixel for pixel, window shadows under it included
    /// (2026-10-19, three displays, max diff 0 outside the glyphs).
    /// Live mode: the live mirror's cover is over the bar and the
    /// assertion is down, so any other picture would film the hidden icons
    /// or the mirror itself. Everyone else's capture runs uncovered.
    static var liveModeBlocksCaptures = false

    /// Windows of ordinary apps (layers below the Dock's): never part of a
    /// picture of the bar that has to stay true for minutes.
    static func ordinaryAppWindows(_ windows: [SCWindow]) -> [SCWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        return windows.filter { $0.windowLayer >= 0 && $0.windowLayer < 20 && $0.owningApplication?.processID != me }
    }

    static func snapshotSet(
        of rect: CGRect?, excludingOwnWindows: Bool = false, ownWindows: [SCWindow]? = nil, primaryOnly: Bool = false,
        displays: Set<CGDirectDisplayID>? = nil, bare: Bool = false, liveMirror: Bool = false
    ) async -> [BarSnapshot] {
        guard !Task.isCancelled, let rect, rect.width > 8 else { return [] }
        if liveModeBlocksCaptures, !liveMirror { return [] }
        if let closed = menuClosedAt {
            let remaining = menuFadeHold - Date().timeIntervalSince(closed)
            if remaining > 0 {
                PelmetLog.log("ghost: capture waits \(Int(remaining * 1000))ms for the menu to fade")
                try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
            }
        }
        guard !Task.isCancelled else { return [] }
        guard ScreenRecordingAccess.isGranted else {
            ScreenRecordingAccess.promptOnce()
            return []
        }
        guard let primary = NSScreen.screens.first else { return [] }

        var shots: [BarSnapshot] = []
        let windowList = onScreenWindows()
        // One lookup per call, shared by every display.
        var content: SCShareableContent?
        let excludingOwnWindows = excludingOwnWindows || bare
        let lookUpOwn = excludingOwnWindows && ownWindows == nil
        for screen in primaryOnly ? [primary] : NSScreen.screens {
            guard !Task.isCancelled else { break }
            guard let displayID = screen.directDisplayID, displays?.contains(displayID) ?? true,
                  let display = await scDisplay(for: displayID) else { continue }
            let bounds = CGDisplayBounds(displayID)  // CG top-left global
            // Bar heights differ per display (39pt notched builtin, 24pt
            // externals) — take each display's own band; visibleFrame can
            // collapse under full-screen apps, so fall back to the safe
            // area, then to the strip's. Cover the bar WINDOW's height
            // (visibleFrame band, 39pt on the notched builtin), not the
            // safe-area inset (38pt): the uncovered bottom row flashed
            // light on a cold reveal — a white line under the icons
            // (2026-09-07). Windows start below the bar window, so its
            // last row is still bar, never a window; a band more than
            // 2pt past the safe area is not the bar and is clamped.
            let safeBand = screen.safeAreaInsets.top
            let visibleBand = screen.frame.maxY - screen.visibleFrame.maxY
            let ownBand = visibleBand > 0 && (safeBand == 0 || visibleBand <= safeBand + 2)
                ? visibleBand : safeBand
            var bandHeight = ownBand > 0 ? ownBand : rect.maxY
            // The bar window is the bar. A visibleFrame band taller than it
            // films a row of what lies under the bar, and the picture pass
            // keyed that row as ink: a line under every tile (#81, a Mac
            // Studio whose main display is external). The same on the
            // builtin (39pt both, 2026-10-13).
            if ownBand > 0, let drawn = GlassPanel.drawnBarHeight(of: screen), drawn < bandHeight {
                let line = "ghost: display \(displayID) band \(Int(bandHeight))pt cut to its bar window's \(Int(drawn))pt"
                if line != lastBandClampLine {
                    lastBandClampLine = line
                    PelmetLog.log(line)
                }
                bandHeight = drawn
            }
            // Right-anchored translation onto this display, padded so the
            // snapshot's background is continuous with the bar around it.
            let translatedX = rect.minX + (screen.frame.maxX - primary.frame.maxX)
            var globalX = max(bounds.minX, translatedX - capturePadding)
            // Never picture the notch: nothing Pelmet manages lives in the
            // cutout, and a notch overlay app's surface hugs it inside the
            // band (Sconce's rest halo baked into the empty-bar picture and
            // floated over every hover reveal for 15 minutes, 2026-09-12).
            if let cutoutRight = screen.auxiliaryTopRightArea?.minX {
                globalX = max(globalX, cutoutRight + 2)
            }
            let width = min(rect.maxX + (screen.frame.maxX - primary.frame.maxX) + capturePadding - globalX, bounds.maxX - globalX)
            guard width > 8, bandHeight > 0 else { continue }
            // sourceRect is display-local top-left; the bar spans the top band.
            let capture = CGRect(x: globalX - bounds.minX, y: 0, width: width, height: bandHeight)
            // Another app's surface over the band (a notch panel wider than
            // the cutout, a HUD) is not the bar — leave it out of the picture.
            // The SCWindow lookup is the slow call, so only pay it on a hit.
            let foreign = foreignBandWindows(
                intersecting: CGRect(x: globalX, y: bounds.minY, width: width, height: bandHeight),
                bandHeight: bandHeight, in: windowList
            )
            var excluded: [SCWindow] = excludingOwnWindows ? ownWindows ?? [] : []
            if !foreign.isEmpty || lookUpOwn || bare {
                let ids = Set(foreign.map(\.id))
                let me = ProcessInfo.processInfo.processIdentifier
                if content == nil {
                    content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
                let systemBars = bare ? content?.windows.filter { Self.isSystemBar($0) && $0.frame.intersects(bounds) } ?? [] : []
                // Without WindowServer's bar left out the picture holds the
                // icons out now, and a held bar would show them.
                if bare, systemBars.isEmpty {
                    PelmetLog.log("ghost: no bar window on display \(displayID) — no bare picture")
                    continue
                }
                excluded += systemBars + (content?.windows.filter {
                    ids.contains($0.windowID) || (lookUpOwn && $0.owningApplication?.processID == me)
                } ?? [])
                if !foreign.isEmpty {
                    PelmetLog.log("ghost: capture leaves out \(foreign.map(\.owner).joined(separator: ", ")) (\(excluded.count) window(s))")
                }
            }
            if liveMirror {
                // A cover that stays up for minutes must not hold a window's
                // edge or the shadow it casts into the bar's last rows: the
                // picture is the bar over the wallpaper, no window in it.
                if content == nil {
                    content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
                let ordinary = ordinaryAppWindows(content?.windows ?? []).filter { $0.frame.intersects(bounds) }
                if !ordinary.isEmpty {
                    excluded += ordinary
                    PelmetLog.log("livemirror: picture leaves out \(ordinary.count) ordinary window(s) and every shadow")
                }
            }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = SCStreamConfiguration()
            if liveMirror { config.ignoreShadowsDisplay = true }
            config.sourceRect = capture
            // The display's own scale — a hardcoded ×2 half-sized the strip
            // on 1× externals.
            let scale = screen.backingScaleFactor
            config.width = Int(capture.width * scale)
            config.height = Int(capture.height * scale)
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            // Flattened like the still: composited with alpha, the stream's
            // band came back ~0.5 luma brighter across the board (rounding
            // through the transparent bar); opaque it matches byte for byte.
            config.shouldBeOpaque = true
            guard let shot = await captureFrame(filter: filter, configuration: config) else {
                PelmetLog.log("ghost: strip capture failed on display \(displayID) — it runs uncovered")
                continue
            }
            shots.append(BarSnapshot(
                image: shot,
                windowFrame: NSRect(
                    x: globalX, y: screen.frame.maxY - bandHeight,
                    width: width, height: bandHeight
                ),
                takenAt: Date()
            ))
        }
        if !shots.isEmpty { lastCaptureAt = Date() }
        return Task.isCancelled ? [] : shots
    }

    /// One frame from an SCStream, the display as it is shown. A
    /// `SCScreenshotManager` still composites the band WITHOUT the shadow
    /// the key window casts up into the bar's bottom rows (nor the window's
    /// top edge under the bar's last row), in every configuration tried,
    /// so its picture floated over the live bar read lighter or darker
    /// across the strip's bottom 12pt for the cover's whole hold (#25,
    /// measured 2026-09-15: +4 luma, +40 on the edge row; a stream frame
    /// matched a `screencapture` still to the pixel). ~90ms end to end
    /// against ~45ms for the still; the reveal's picture is precaptured, so
    /// none of it lands on the hover path.
    private static let captureQueue = DispatchQueue(label: "app.fif7y.Pelmet.ghost.capture")

    private static func captureFrame(filter: SCContentFilter, configuration: SCStreamConfiguration) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let sink = FirstFrameSink()
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
        } catch {
            PelmetLog.log("ghost: stream capture failed to start — \(error.localizedDescription)")
            return nil
        }
        let image = await sink.firstImage(timeout: .milliseconds(600))
        // The stop is ~20ms the caller never needs to wait for.
        Task { try? await stream.stopCapture() }
        return image
    }

    /// The Smooth exit slides the icons alone. SCK cannot hand them over
    /// (excluding the wallpaper window drops the bar's items too — they are
    /// drawn inside the WindowServer-owned Menubar window, probed
    /// 2026-09-08), so the glyphs are cut out by difference against the
    /// empty-bar capture taken at the last conceal settle: a pixel that
    /// matches the background is background. `punch` lists x-ranges
    /// cleared regardless —
    /// the chevron flips glyph between the two captures (absolute x, points,
    /// same origin as the strip frames). Where the captures don't overlap
    /// the strip stays opaque; a strip that differs almost everywhere
    /// (animated wallpaper) returns nil and the caller falls back to the
    /// agent's animation.
    static func iconsOnly(
        _ strips: [BarSnapshot], background: [BarSnapshot],
        punch: [ClosedRange<CGFloat>] = [], keep: ClosedRange<CGFloat>? = nil
    ) -> [BarSnapshot]? {
        var out: [BarSnapshot] = []
        for strip in strips {
            guard let bg = background.first(where: {
                abs($0.windowFrame.minY - strip.windowFrame.minY) < 1
                    && $0.windowFrame.intersects(strip.windowFrame)
            }) else {
                PelmetLog.log("ghost: cut-out skipped — no background under the strip @x=\(Int(strip.windowFrame.minX))")
                return nil
            }
            guard var cut = cutOut(strip: strip, background: bg, punch: punch) else { return nil }
            var frame = strip.windowFrame
            // Only the strip's own columns: a system icon at the picture's
            // edge that changed between the captures (AirPods state,
            // battery %) must not ride the slide — and a window that ends
            // at the strip's edge CLIPS the slide, so the icons emerge from
            // behind the chevron instead of crossing over it.
            if let keep {
                let dx = strip.windowFrame.minX - primaryOffset(of: strip, in: strips)
                let scale = CGFloat(cut.width) / strip.windowFrame.width
                let x0 = max(0, (keep.lowerBound + dx - strip.windowFrame.minX) * scale)
                let x1 = min(CGFloat(cut.width), (keep.upperBound + dx - strip.windowFrame.minX) * scale)
                guard x1 - x0 > 4 * scale,
                      let cropped = cut.cropping(to: CGRect(x: x0.rounded(), y: 0, width: (x1 - x0).rounded(), height: CGFloat(cut.height)))
                else {
                    PelmetLog.log("ghost: cut-out skipped — keep \(Int(keep.lowerBound))..\(Int(keep.upperBound)) maps to \(Int(x0))..\(Int(x1)) px on the strip @x=\(Int(strip.windowFrame.minX))")
                    return nil
                }
                cut = cropped
                frame = NSRect(
                    x: strip.windowFrame.minX + x0.rounded() / scale, y: frame.minY,
                    width: (x1 - x0).rounded() / scale, height: frame.height
                )
            }
            out.append(BarSnapshot(image: cut, windowFrame: frame, takenAt: strip.takenAt))
        }
        return out.isEmpty ? nil : out
    }

    /// The same pictures with `columns` (absolute x, points) made
    /// transparent — the empty-bar cover with the chevron cut out, so the
    /// real chevron (which flips at the swap) shows through instead of the
    /// picture's stale glyph.
    static func clearing(_ snaps: [BarSnapshot], columns: [ClosedRange<CGFloat>]) -> [BarSnapshot] {
        guard !columns.isEmpty else { return snaps }
        return snaps.map { snap in
            let w = snap.image.width, h = snap.image.height
            guard let px = rgba(snap.image, width: w, height: h) else { return snap }
            let scale = CGFloat(w) / snap.windowFrame.width
            for range in columns {
                let x0 = max(0, Int(((range.lowerBound - snap.windowFrame.minX) * scale).rounded()))
                let x1 = min(w, Int(((range.upperBound - snap.windowFrame.minX) * scale).rounded()))
                guard x1 > x0 else { continue }
                for y in 0..<h {
                    let row = px.pointer + y * px.stride
                    for x in x0..<x1 { (row + x * 4).update(repeating: 0, count: 4) }
                }
            }
            guard let image = px.context.makeImage() else { return snap }
            return BarSnapshot(image: image, windowFrame: snap.windowFrame, takenAt: snap.takenAt)
        }
    }

    /// The same pictures narrowed to `span` (absolute x in points, primary
    /// coordinates — every other display holds the right-anchored
    /// translation, as in `snapshotSet`), padded the way a capture of that
    /// span would have been so the background stays continuous.
    ///
    /// All or nothing: a picture that does not reach both ends of the span
    /// is dropped and the caller captures live. A cover with a gap at one
    /// end shows the round trip it exists to hide.
    static func cropped(_ snaps: [BarSnapshot], toPrimaryX span: ClosedRange<CGFloat>) -> [BarSnapshot] {
        guard !snaps.isEmpty, span.upperBound - span.lowerBound > 8,
              let primaryMaxX = NSScreen.screens.first?.frame.maxX
        else { return [] }
        var out: [BarSnapshot] = []
        for snap in snaps {
            let frame = snap.windowFrame
            guard let screen = NSScreen.screens.first(where: {
                $0.frame.intersects(frame)
            }) else { return [] }
            let shift = screen.frame.maxX - primaryMaxX
            guard let columns = cropColumns(
                span: (span.lowerBound + shift)...(span.upperBound + shift),
                frame: frame, imageWidth: snap.image.width
            ) else { return [] }
            let scale = CGFloat(snap.image.width) / frame.width
            guard let image = snap.image.cropping(to: CGRect(
                x: columns.lowerBound, y: 0,
                width: columns.count, height: snap.image.height
            )) else { return [] }
            out.append(BarSnapshot(
                image: image,
                windowFrame: NSRect(
                    x: frame.minX + CGFloat(columns.lowerBound) / scale, y: frame.minY,
                    width: CGFloat(columns.count) / scale, height: frame.height
                ),
                takenAt: snap.takenAt
            ))
        }
        return out
    }

    /// The pixel columns of `span` inside a picture that floats at `frame`,
    /// padded the way `snapshotSet` pads a capture of that span. Nil when
    /// the picture does not reach both ends, or when what is left is too
    /// narrow to float. Pure geometry, so the crop is testable without a
    /// display (see `BarSnapshotCropTests`).
    static func cropColumns(span: ClosedRange<CGFloat>, frame: NSRect, imageWidth: Int) -> Range<Int>? {
        guard frame.width > 0, imageWidth > 0 else { return nil }
        // The leading side is clamped, not required: `snapshotSet` stops a
        // capture at the notch and the display edge, and a cover rect that
        // budgets for icons sliding in routinely starts off-screen (a blink
        // cover measured -430 on a bar starting at 0). A live capture of
        // that span would have been cut at the same place, so a picture
        // that starts there is not short — it is the same picture.
        let wantMinX = max(span.lowerBound - capturePadding, frame.minX)
        // The trailing side is required: it lands just short of the clock,
        // and a picture cut before it would leave the clock uncovered.
        let wantMaxX = span.upperBound + capturePadding
        guard wantMaxX <= frame.maxX + 0.5 else { return nil }
        let scale = CGFloat(imageWidth) / frame.width
        let x0 = max(0, Int(((wantMinX - frame.minX) * scale).rounded()))
        let x1 = min(imageWidth, Int(((wantMaxX - frame.minX) * scale).rounded()))
        guard x1 - x0 > 8 else { return nil }
        return x0..<x1
    }

    /// Snapshots on other displays are the primary strip translated
    /// right-anchored (snapshotSet); `keep` is given in primary coordinates.
    /// The primary strip is the one on the primary display — not the one
    /// nearest x=0: a display parked left of the primary put its strip at
    /// x=-864 against the primary's 1012, and `keep` mapped off the picture
    /// (2026-09-18, three displays).
    /// How far this strip sits from the primary's, by RIGHT edges: the
    /// translation is right-anchored, and only the primary capture's left
    /// edge can be clamped to the notch (snapshotSet). Measured by left
    /// edges, a primary strip clamped 124pt in put the keep crop 124pt too
    /// far left on the external display — Saturn, Snib and Sound fell off
    /// the picture and popped in at lift (2026-10-02).
    private static func primaryOffset(of strip: BarSnapshot, in strips: [BarSnapshot]) -> CGFloat {
        let primaryFrame = NSScreen.screens.first?.frame ?? .zero
        let primary = strips.first { primaryFrame.contains(CGPoint(x: $0.windowFrame.midX, y: primaryFrame.midY)) }
            ?? strips.min(by: { abs($0.windowFrame.minX) < abs($1.windowFrame.minX) })
        guard let primary else { return 0 }
        // The caller subtracts this from the strip's minX to get its offset.
        return strip.windowFrame.minX - (strip.windowFrame.maxX - primary.windowFrame.maxX)
    }

    private static func cutOut(
        strip: BarSnapshot, background bg: BarSnapshot, punch: [ClosedRange<CGFloat>]
    ) -> CGImage? {
        let overlap = strip.windowFrame.intersection(bg.windowFrame)
        guard overlap.width > 4 else {
            PelmetLog.log("ghost: cut-out skipped — strip and background don't overlap")
            return nil
        }
        let scale = CGFloat(strip.image.width) / strip.windowFrame.width
        guard abs(CGFloat(bg.image.width) / bg.windowFrame.width - scale) < 0.01 else {
            PelmetLog.log("ghost: cut-out skipped — strip and background scales differ")
            return nil
        }
        let w = strip.image.width, h = min(strip.image.height, bg.image.height)
        guard let a = rgba(strip.image, width: w, height: h),
              let b = rgba(bg.image, width: bg.image.width, height: h) else { return nil }
        let ax0 = Int(((overlap.minX - strip.windowFrame.minX) * scale).rounded())
        let bx0 = Int(((overlap.minX - bg.windowFrame.minX) * scale).rounded())
        let span = min(Int((overlap.width * scale).rounded()), w - ax0, bg.image.width - bx0)
        guard span > 0 else { return nil }
        var changed = 0
        for y in 0..<h {
            let arow = a.pointer + y * a.stride
            let brow = b.pointer + y * b.stride
            for i in 0..<span {
                let ap = arow + (ax0 + i) * 4
                let bp = brow + (bx0 + i) * 4
                let d = max(
                    abs(Int(ap[0]) - Int(bp[0])),
                    abs(Int(ap[1]) - Int(bp[1])),
                    abs(Int(ap[2]) - Int(bp[2]))
                )
                // Soft key: identical → gone, 26+ levels off → kept whole.
                let alpha = d <= 6 ? 0 : d >= 26 ? 255 : (d - 6) * 255 / 20
                if alpha == 255 { changed += 1 }
                if alpha < 255 {
                    ap[0] = UInt8(Int(ap[0]) * alpha / 255)
                    ap[1] = UInt8(Int(ap[1]) * alpha / 255)
                    ap[2] = UInt8(Int(ap[2]) * alpha / 255)
                    ap[3] = UInt8(alpha)
                }
            }
        }
        for range in punch {
            let x0 = max(0, Int(((range.lowerBound - strip.windowFrame.minX) * scale).rounded()))
            let x1 = min(w, Int(((range.upperBound - strip.windowFrame.minX) * scale).rounded()))
            guard x1 > x0 else { continue }
            for y in 0..<h {
                let row = a.pointer + y * a.stride
                for x in x0..<x1 { (row + x * 4).update(repeating: 0, count: 4) }
            }
        }
        let ratio = Double(changed) / Double(span * h)
        guard ratio < 0.6 else {
            PelmetLog.log("ghost: cut-out skipped — \(Int(ratio * 100))% of the strip differs from the background")
            return nil
        }
        return a.context.makeImage()
    }

    private struct Pixels {
        let context: CGContext
        let pointer: UnsafeMutablePointer<UInt8>
        let stride: Int
    }

    /// Premultiplied BGRA8 copy of `image`, `width`×`height` from its top-left.
    private static func rgba(_ image: CGImage, width: Int, height: Int) -> Pixels? {
        let stride = width * 4
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let data = context.data else { return nil }
        // Anchor the top rows: both captures share the bar's top edge.
        context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        return Pixels(context: context, pointer: data.assumingMemoryBound(to: UInt8.self), stride: stride)
    }

    /// The same picture with every column from `x` on (global Cocoa points,
    /// like `windowFrame`) replaced by a copy of the column just left of it:
    /// the bar's own background, nothing else. A picture of the concealed bar
    /// is taken while the capture indicator lights and moves the cluster at
    /// the bar's right end, so its last columns hold the « and the extras
    /// caught mid-slide (and the 6pt of padding past the requested edge holds
    /// what stood next to it). The cover stops left of where the « settled; a
    /// later cover from the same kept picture may reach further right (the
    /// indicator gone, the « back at its resting place) and must show bar,
    /// not those. Pixel-exact left of `x`: drawn in the picture's own colour
    /// space, no conversion.
    static func smeared(_ snap: BarSnapshot, from x: CGFloat) -> BarSnapshot {
        let w = snap.image.width, h = snap.image.height
        let scale = CGFloat(w) / snap.windowFrame.width
        let x0 = Int(((x - snap.windowFrame.minX) * scale).rounded(.down))
        guard x0 > 1, x0 < w,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: snap.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let column = snap.image.cropping(to: CGRect(x: x0 - 1, y: 0, width: 1, height: h))
        else { return snap }
        ctx.draw(snap.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .none
        ctx.draw(column, in: CGRect(x: x0, y: 0, width: w - x0, height: h))
        guard let out = ctx.makeImage() else { return snap }
        return BarSnapshot(image: out, windowFrame: snap.windowFrame, takenAt: snap.takenAt)
    }

    /// Capture now and float immediately. Call `fadeOut()`/`dismiss()` once
    /// the swap beneath has been issued; a safety timeout fades regardless.
    static func begin(over rect: CGRect?, safety: TimeInterval = 0.5) async -> GhostSet? {
        begin(from: await snapshotSet(of: rect), safety: safety)
    }

    /// Float pre-captured snapshots — synchronous, zero capture latency.
    /// `holdsBar`: a bar kept looking concealed for a whole reveal (#88). It
    /// takes the clicks on it, so none lands on an icon it hides, without
    /// making Pelmet the active app.
    static func begin(
        from snaps: [BarSnapshot], safety: TimeInterval = 0.5, startHidden: Bool = false, holdsBar: Bool = false
    ) -> GhostSet? {
        guard !snaps.isEmpty else { return nil }
        // A cover orders in above every window at the bar's level, another
        // app's surface included: Sconce's notch glass lost its top 39pt
        // behind Pelmet's picture of the bar while it opened (2026-09-12).
        // With a foreign surface over the strip the cover slips in BELOW it
        // — the bar's own animation is still hidden, the surface still
        // draws on top. Per display: a notchless external carries Sconce's
        // rest bar at top center, permanently.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return GhostSet(overlays: snaps.map { snap in
            let f = snap.windowFrame
            let cg = CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height)
            let foreign = foreignBandWindows(intersecting: cg, bandHeight: f.height)
            if !foreign.isEmpty {
                PelmetLog.log("ghost: cover under \(foreign.map(\.owner).joined(separator: ", ")) @x=\(Int(f.minX))")
            }
            return ConcealGhostOverlay(snapshot: snap, safety: safety, startHidden: startHidden, beneath: foreign.first?.id, holdsBar: holdsBar)
        })
    }

    private init(
        snapshot: BarSnapshot, safety: TimeInterval, startHidden: Bool = false, beneath: CGWindowID? = nil, holdsBar: Bool = false
    ) {
        let frame = snapshot.windowFrame
        let shot = snapshot.image
        Self.nextID += 1
        id = Self.nextID
        beneathID = beneath
        countsAsStrip = !holdsBar
        if holdsBar {
            let panel = HeldBarPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            // Up for a whole reveal: on every Space of its display. Transient,
            // not stationary: a stationary one stayed in Mission Control, a
            // dark band over the Spaces bar (#108). The window server hides it
            // with the bar, and its stationary twin covers its way back
            // (`watchMissionControl`).
            panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            // A cut, not the window server's default: ordered in it grows ~5pt
            // and fades up over ~60ms, ordered out it shrinks 5pt and fades
            // over ~170ms (a held cover on the bar must neither dim the bar
            // under it nor move its edges). Measured, 2026-10-28.
            panel.animationBehavior = .none
            window = panel
        } else {
            window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = !holdsBar
        window.hasShadow = false
        imageView = NSImageView(
            image: NSImage(cgImage: shot, size: frame.size)
        )
        imageView.frame = NSRect(origin: .zero, size: frame.size)
        imageView.wantsLayer = true
        if startHidden { imageView.layer?.opacity = 0 }
        // A layer-hosting root: a layer added into the image view's own
        // (AppKit-managed) layer dropped out for single frames every
        // ~180ms (Gab's clicks at 60fps, 2026-09-22 15:16), a shade that
        // flickered. Sublayers of a root we own are left alone.
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.layer = CALayer()
        root.wantsLayer = true
        root.addSubview(imageView)
        window.contentView = root
        if let beneath {
            window.order(.below, relativeTo: Int(beneath))
        } else {
            window.orderFrontRegardless()
        }
        window.displayIfNeeded()
        if holdsBar {
            twin = Self.makeTwin(of: shot, frame: frame)
            twin?.order(.below, relativeTo: window.windowNumber)
            twinPicture = shot
            scheduleTwinShape()
        }
        if countsAsStrip { Self.activeStripCount += 1 }
        Self.register(self)
        if holdsBar, Self.missionWatch == nil { Self.watchMissionControl(every: Self.watchRest) }
        PelmetLog.log("ghost: \(holdsBar ? "held bar" : "strip") #\(id) up \(Int(frame.width))×\(Int(frame.height)) @x=\(Int(frame.minX)) safety \(Int(safety * 1000))ms")
        // Safety: never leave a stale cover if the caller's task dies.
        // Strong self on purpose: a cover nobody held any more (#52, a
        // shaded picture raised after its blink had been dismissed) was
        // freed with its window still ordered in, and a weak timer had
        // nothing left to fade. The window is what stays on screen, so
        // the timer must be what keeps the cover alive until it lifts.
        safetyEnd = Date().addingTimeInterval(safety)
        armSafety(after: safety)
    }

    /// Checks at least once a minute: the timer holds the cover, and a held
    /// bar's safety runs up to a day (`anchoredBarCeiling`), so a cover
    /// lifted early kept its window and picture until then.
    private func armSafety(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + min(delay, 60)) { [self] in
            guard !finished else { return }
            let left = safetyEnd.timeIntervalSinceNow
            if left > 0.01 {
                armSafety(after: left)
                return
            }
            PelmetLog.log("ghost: strip #\(id) safety fade")
            fadeOut()
        }
    }

    func keepUp(for seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        if end > safetyEnd { safetyEnd = end }
    }

    func passClicks(_ through: Bool) {
        window.ignoresMouseEvents = through || countsAsStrip
    }

    // MARK: Live mode

    var windowNumber: Int { window.windowNumber }

    /// Live mode's cover (set by the live mirror). Everything under it is
    /// meant to be gone, as the real icons are: a ghost (the fading copy of an
    /// item Dimble hides) would stay above the cover and cross the mirror
    /// that slides in (Smooth, a re-hide, ~100 ms, measured 2026-10-28).
    var isLiveCover = false

    /// A live cover is up over `rect` (global Cocoa points).
    static func liveCover(over rect: NSRect) -> Bool {
        registry.allObjects.contains { $0.isLiveCover && !$0.finished && $0.window.isVisible && $0.window.frame.intersects(rect) }
    }

    /// Shortens the cover from the right, in place: the picture stays where it
    /// is and the window just ends sooner (a new window for a shorter cover
    /// left a gap of three frames, and the layers in it had to move).
    func clip(toMaxX x: CGFloat) {
        guard !finished else { return }
        var frame = window.frame
        guard x < frame.maxX, x > frame.minX else { return }
        frame.size.width = x - frame.minX
        window.setFrame(frame, display: true)
        twin?.setFrame(frame, display: false)
        // The « moved, and the icons with it: the twin's cut is stale.
        if twin != nil { scheduleTwinShape() }
    }

    /// Directly below another cover: the one above stays what is seen while
    /// this one is already up beneath it (a hand-over with no gap).
    func order(beneath other: ConcealGhostOverlay) {
        guard !finished else { return }
        window.order(.below, relativeTo: other.windowNumber)
    }
    var windowFrame: NSRect { window.frame }

    /// Every click on the picture goes to `hook` (global Cocoa point).
    func setClickHook(_ hook: ((NSPoint) -> Void)?) {
        (window as? HeldBarPanel)?.clickHook = hook
    }

    /// A layer over the picture, in the picture's own coordinates.
    func addLayer(_ layer: CALayer) {
        guard let root = window.contentView?.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.addSublayer(layer)
        CATransaction.commit()
    }

    /// Out of the way (the real bar shows) or back over it, no animation.
    func setShown(_ shown: Bool) {
        guard !finished else { return }
        if !shown { window.orderOut(nil); return }
        orderBelowForeign()
    }

    /// The live cover's rule: directly below every foreign surface over its
    /// strip (Sconce's notch glass and the like), found fresh each time (their
    /// window numbers change when they redraw), the lowest of them when there
    /// are several. Nothing foreign over the strip: in front. Returns the
    /// surface it went below.
    @discardableResult
    func orderBelowForeign() -> (owner: String, id: CGWindowID)? {
        guard !finished else { return nil }
        let f = window.frame
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let cg = CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height)
        let foreign = Self.foreignBandWindows(intersecting: cg, bandHeight: f.height)
        if let lowest = foreign.last {
            beneathID = lowest.id
            window.order(.below, relativeTo: Int(lowest.id))
            return lowest
        }
        beneathID = nil
        window.orderFrontRegardless()
        return nil
    }

    /// Every cover alive (the live mirror's, a reveal's strip, a held bar, a
    /// finished picture), weakly: the live-mode rule keeps all of them below
    /// the foreign surfaces, whoever made them.
    private static let registry = NSHashTable<ConcealGhostOverlay>.weakObjects()
    static func register(_ overlay: ConcealGhostOverlay) { registry.add(overlay); onNewCover?() }
    /// Told whenever a cover is made: the live mirror checks the order at
    /// once and again shortly after, not at its next idle tick.
    static var onNewCover: (() -> Void)?
    static var coverCount: Int { registry.allObjects.filter { !$0.finished }.count }

    /// Puts every cover that sits above a foreign surface back below it;
    /// says which it moved.
    static func keepBelowForeign() -> [String] {
        let covers = registry.allObjects.filter { !$0.finished }
        guard !covers.isEmpty, let list = onScreenWindows() else { return [] }
        var moved: [String] = []
        for cover in covers {
            guard let above = cover.foreignBelowMe(in: list) else { continue }
            let now = cover.orderBelowForeign()
            moved.append("#\(cover.id) was above \(above.owner) \(above.id), now below \(now.map { "\($0.owner) \($0.id)" } ?? "?")")
        }
        return moved
    }

    /// A foreign surface over the strip that has slipped below this cover
    /// (a click on the cover orders it in front of its level), by the
    /// window server's front-to-back `list`.
    func foreignBelowMe(in list: [[String: Any]]) -> (owner: String, id: CGWindowID)? {
        guard window.isVisible, !finished else { return nil }
        let f = window.frame
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let cg = CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height)
        let foreign = Self.foreignBandWindows(intersecting: cg, bandHeight: f.height, in: list)
        guard !foreign.isEmpty else { return nil }
        func index(_ id: CGWindowID) -> Int? {
            list.firstIndex { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
        }
        guard let mine = index(CGWindowID(window.windowNumber)) else { return nil }
        return foreign.first { (index($0.id) ?? -1) > mine }
    }

    // MARK: Mission Control

    /// On its way out of Mission Control the window server brings the bar
    /// back at once but fades a transient window in over ~280 ms: every
    /// icon a held bar hides showed through it for ~150 ms (measured
    /// 2026-10-28). Each held bar has a stationary twin of its picture,
    /// invisible (a stationary window is what stayed over the Spaces bar),
    /// that goes opaque the moment the held bar is listed on screen again
    /// (the bar's first frame, measured) and clears once the fade is done.
    /// Looked at every 100 ms while held bars are up, every 8 ms while one
    /// is away.
    private static var missionWatch: Timer?
    private static var awayHeld: Set<Int> = []
    private static let watchRest: TimeInterval = 0.1
    private static let watchAway: TimeInterval = 0.008
    private static let twinHold: TimeInterval = 0.4
    /// After the held bar goes up: the icons it hides are out by then
    /// (a reveal's slide is 320 ms), and the hold's own capture still has
    /// the capture indicator lit.
    private static let twinShapeDelay: TimeInterval = 1.0
    /// Pixels kept around each glyph's ink.
    private static let twinSpread = 2

    private static func makeTwin(of shot: CGImage, frame: NSRect) -> NSWindow {
        let twin = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        twin.hidesOnDeactivate = false
        twin.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        twin.animationBehavior = .none
        twin.isOpaque = false
        twin.backgroundColor = .clear
        twin.level = .statusBar
        twin.hasShadow = false
        twin.ignoresMouseEvents = true
        twin.alphaValue = 0
        let view = NSImageView(image: NSImage(cgImage: shot, size: frame.size))
        view.frame = NSRect(origin: .zero, size: frame.size)
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.addSubview(view)
        twin.contentView = root
        return twin
    }

    private func dropTwin() {
        twin?.orderOut(nil)
        twin = nil
        twinPicture = nil
    }

    /// Where the bar's icons stand now (AppState: the «'s window and every
    /// item's AX frame). A twin cut to the icons only serves while this
    /// reads the same as when it was cut.
    static var iconLayout: (() -> [Int])?

    /// The latest call wins: a cut waits out the icons settling.
    private func scheduleTwinShape() {
        twinShapeGeneration += 1
        let generation = twinShapeGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.twinShapeDelay))
            guard let self, generation == twinShapeGeneration else { return }
            await shapeTwin()
        }
    }

    private func setTwinPicture(_ image: CGImage) {
        guard let twin, let picture = twinPicture else { return }
        let scale = window.backingScaleFactor
        let size = NSSize(width: CGFloat(picture.width) / scale, height: CGFloat(picture.height) / scale)
        (twin.contentView?.subviews.first as? NSImageView)?.image = NSImage(cgImage: image, size: size)
    }

    /// Cuts the twin down to the icons the held bar hides, plus a couple of
    /// pixels. Whole, it snapped opaque over the Spaces bar still sliding
    /// out of the band at a Mission Control close: with many Desktops their
    /// names showed cut off at the cover's edge for ~120 ms, a block on a
    /// light wallpaper (#108, 2026-10-30). The icons are WindowServer's
    /// Menubar window filmed alone, glyphs on clear. It films empty while
    /// Mission Control is up, so this runs once the held bar has settled.
    /// Only while the capture indicator is already lit: a capture that
    /// lights it shifts the bar 3pt, which re-holds, which would capture
    /// again. Any miss keeps the whole twin.
    private func shapeTwin() async {
        guard twin != nil, !finished, let picture = twinPicture, listedOnScreen else { return }
        let layout = Self.iconLayout?()
        if twinLayout != nil, twinLayout != layout { wholeTwin() }
        guard twinLayout == nil else { return }
        guard Self.captureIndicatorLit else {
            PelmetLog.log("ghost: held bar #\(id) twin stays whole — the capture indicator is out")
            return
        }
        guard let glyphs = await Self.barGlyphs(in: window.frame, scale: window.backingScaleFactor) else {
            PelmetLog.log("ghost: held bar #\(id) twin stays whole — no picture of the bar's icons")
            return
        }
        guard twin != nil, !finished, twinPicture === picture else { return }
        guard let layout, Self.iconLayout?() == layout else {
            PelmetLog.log("ghost: held bar #\(id) twin stays whole — the icons moved while they were filmed")
            return
        }
        guard let shaped = Self.iconShaped(picture, glyphs: glyphs, spread: Self.twinSpread) else {
            PelmetLog.log("ghost: held bar #\(id) twin stays whole — no icons under it")
            return
        }
        setTwinPicture(shaped.image)
        twinLayout = layout
        PelmetLog.log("ghost: held bar #\(id) twin cut to its icons (\(Int(shaped.share * 100))% of the picture)")
    }

    private func wholeTwin() {
        guard let picture = twinPicture else { return }
        setTwinPicture(picture)
        twinLayout = nil
    }

    /// WindowServer's Menubar window over `frame` (global Cocoa points),
    /// filmed alone: the bar's glyphs on clear, whatever covers them.
    private static func barGlyphs(in frame: NSRect, scale: CGFloat) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let cg = CGRect(x: frame.minX, y: primaryMaxY - frame.maxY, width: frame.width, height: frame.height)
        guard let bar = content.windows.first(where: { isSystemBar($0) && $0.frame.intersects(cg) }) else { return nil }
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: cg.minX - bar.frame.minX, y: cg.minY - bar.frame.minY, width: cg.width, height: cg.height)
        config.width = Int((cg.width * scale).rounded())
        config.height = Int((cg.height * scale).rounded())
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.shouldBeOpaque = false
        let image = await captureFrame(filter: SCContentFilter(desktopIndependentWindow: bar), configuration: config)
        if image != nil { lastCaptureAt = Date() }
        return image
    }

    /// `picture` kept only where `glyphs` has ink, spread `spread` px each
    /// way, clear elsewhere, and the share of it kept. Drawn in the
    /// picture's own colour space, so what is kept matches the held bar
    /// pixel for pixel. Nil with no ink, or with ink over most of it (not
    /// a bar of icons).
    static func iconShaped(_ picture: CGImage, glyphs: CGImage, spread: Int) -> (image: CGImage, share: Double)? {
        let w = picture.width, h = picture.height
        guard let ink = rgba(glyphs, width: w, height: h),
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: picture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = ctx.data
        else { return nil }
        ctx.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
        // A square max filter, rows then columns.
        var wide = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let row = ink.pointer + y * ink.stride
            for x in 0..<w where row[x * 4 + 3] > 8 {
                for dx in max(0, x - spread)...min(w - 1, x + spread) { wide[y * w + dx] = true }
            }
        }
        var keep = wide
        for y in 0..<h {
            for x in 0..<w where wide[y * w + x] {
                for dy in max(0, y - spread)...min(h - 1, y + spread) { keep[dy * w + x] = true }
            }
        }
        let px = data.assumingMemoryBound(to: UInt8.self)
        var kept = 0
        for i in 0..<(w * h) {
            if keep[i] { kept += 1 } else { (px + i * 4).update(repeating: 0, count: 4) }
        }
        let share = Double(kept) / Double(w * h)
        guard kept > 0, share < 0.6, let image = ctx.makeImage() else { return nil }
        return (image: image, share: share)
    }

    private static func watchMissionControl(every interval: TimeInterval) {
        missionWatch?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { checkHeldBars(interval) }
        }
        RunLoop.main.add(timer, forMode: .common)
        missionWatch = timer
    }

    private static func checkHeldBars(_ interval: TimeInterval) {
        let held = registry.allObjects.filter { $0.twin != nil && !$0.finished && $0.window.isVisible }
        guard !held.isEmpty else {
            missionWatch?.invalidate()
            missionWatch = nil
            awayHeld = []
            return
        }
        awayHeld.formIntersection(held.map(\.id))
        for cover in held {
            if !cover.listedOnScreen {
                if awayHeld.insert(cover.id).inserted { PelmetLog.log("ghost: held bar #\(cover.id) off screen (Mission Control or the like)") }
            } else if awayHeld.remove(cover.id) != nil {
                cover.showTwin()
            }
        }
        let want = awayHeld.isEmpty ? watchRest : watchAway
        if want != interval { watchMissionControl(every: want) }
    }

    private var listedOnScreen: Bool {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]])?.first
        return (info?[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    private func showTwin() {
        guard let twin, (imageView.layer?.opacity ?? 1) > 0.99 else { return }
        // Icons that moved under a twin cut to them would show beside it.
        let stale = twinLayout != nil && Self.iconLayout?() != twinLayout
        if stale { wholeTwin() }
        twin.order(.below, relativeTo: window.windowNumber)
        twin.alphaValue = 1
        let kind = twinLayout != nil ? "its twin, cut to the icons," : stale ? "its whole twin (the icons moved since the cut)" : "its whole twin"
        PelmetLog.log("ghost: held bar #\(id) back — \(kind) covers the window server's fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.twinHold) { [weak self] in self?.twin?.alphaValue = 0 }
    }

    /// One decrement per overlay, however it ends.
    private func standDown() {
        guard !stoodDown else { return }
        stoodDown = true
        if countsAsStrip { Self.activeStripCount -= 1 }
    }

    func addPanelShade() {
        guard !finished, let root = window.contentView?.layer else { return }
        let shade = CAGradientLayer()
        shade.frame = root.bounds
        // Layer space is bottom-up: the darker end is the bar's bottom row.
        shade.colors = [CGColor(gray: 0, alpha: 0.11), CGColor(gray: 0, alpha: 0.035)]
        shade.startPoint = CGPoint(x: 0.5, y: 0); shade.endPoint = CGPoint(x: 0.5, y: 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.addSublayer(shade)
        CATransaction.commit()
    }

    /// A wipe from the right that replays Notification Center's own
    /// slide: the root layer takes a mask whose soft left edge (`edge`
    /// points, the panel's blurred leading edge under the glass) sits at
    /// `insets[i]` points in from the display's right edge at frame `i`,
    /// starting `delay` seconds from now. The picture carries the exact
    /// look of the bar under the panel; the mask carries its motion.
    func wipeInFromRight(insets: [CGFloat], frame: CFTimeInterval, delay: CFTimeInterval, edge: CGFloat) {
        guard !finished, insets.count >= 2, let root = window.contentView?.layer,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) else { return }
        let width = window.frame.width
        let mask = CAGradientLayer()
        mask.frame = CGRect(x: 0, y: 0, width: width * 2 + edge, height: window.frame.height)
        mask.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1)]
        mask.locations = [0, NSNumber(value: Double(min(1, edge / max(mask.frame.width, 1)))), 1]
        mask.startPoint = CGPoint(x: 0, y: 0.5); mask.endPoint = CGPoint(x: 1, y: 0.5)
        // Layer x of the soft edge's left end for a panel edge `inset` in.
        func x(_ inset: CGFloat) -> CGFloat { screen.frame.maxX - inset - window.frame.minX - edge / 2 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.transform = CATransform3DMakeTranslation(x(insets[0]), 0, 0)
        root.mask = mask
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = insets.map { x($0) }
        anim.calculationMode = .linear
        anim.duration = frame * Double(insets.count - 1)
        anim.beginTime = mask.convertTime(CACurrentMediaTime(), from: nil) + delay
        anim.fillMode = .backwards
        mask.add(anim, forKey: "pelmetWipe")
        mask.transform = CATransform3DMakeTranslation(x(insets[insets.count - 1]), 0, 0)
        CATransaction.commit()
    }

    /// Drop the cover with no animation — the Instant reveal style: whatever
    /// landed beneath simply is, from one frame to the next. Idempotent.
    func dismiss() {
        guard !finished else { return }
        finished = true
        window.orderOut(nil)
        dropTwin()
        standDown()
    }

    /// Ease-out into rest, ease-in away — the agent's own curves.
    func animate(_ move: AnimationRecipe.Move, entering: Bool) {
        guard !finished, let layer = imageView.layer else { return }
        // Slides keep the agent's own curves (ease-out in, ease-in away);
        // fades run symmetric so the whole duration reads as a crossfade.
        let slideCurve: (Float, Float, Float, Float) = entering ? (0.16, 1, 0.3, 1) : (0.55, 0, 0.8, 0.4)
        let fadeCurve: (Float, Float, Float, Float) = (0.42, 0, 0.58, 1)
        let curve = { if case .slide = move { return slideCurve } else { return fadeCurve } }()
        // The start state must be ON the layer before the animation reads
        // its "from" — a picture floated with startHidden may not have had
        // a layer yet when its opacity was zeroed.
        if entering, case .pop = move {} else if entering { layer.opacity = 0 }
        switch move {
        case .pop:
            return
        case .fade(let duration):
            if entering {
                AlphaFade.run(imageView, to: 1, duration: duration, controlPoints: curve)
            } else {
                fadeOut(duration: duration, controlPoints: curve)
            }
        case .slide(let dx, let duration):
            let rest = layer.position.x
            let away = rest + dx
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = entering ? away : rest
            slide.toValue = entering ? rest : away
            slide.duration = duration
            slide.timingFunction = CAMediaTimingFunction(controlPoints: curve.0, curve.1, curve.2, curve.3)
            layer.add(slide, forKey: "pelmetSlide")
            layer.position.x = entering ? rest : away
            if entering {
                // Opaque early so the travel itself reads, not just a fade.
                AlphaFade.run(imageView, to: 1, duration: min(duration, 0.14), controlPoints: curve)
            } else {
                fadeOut(duration: duration)
            }
        }
    }

    /// Fade the cover out — ease-in (holds visibility, then accelerates away),
    /// the mirror of the show fade's ease-out. Idempotent. `slide` adds a
    /// drift toward the chevron (the Smooth exit's tuck-away).
    static let dismissDuration: CFTimeInterval = 0.16

    func fadeOut(
        duration: CFTimeInterval = ConcealGhostOverlay.dismissDuration, slide: Bool = false,
        controlPoints: (Float, Float, Float, Float) = (0.55, 0, 0.8, 0.4)
    ) {
        guard !finished else { return }
        finished = true
        dropTwin()
        // A held bar on its way out is the bar beneath: clicks go through.
        window.ignoresMouseEvents = true
        if slide, let layer = imageView.layer {
            let shift = min(imageView.bounds.width * 0.5, 80)
            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = layer.position.x
            anim.toValue = layer.position.x + shift
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.4)
            layer.add(anim, forKey: "pelmetSlideOut")
            layer.position.x += shift
        }
        // Strong self: the completion is the count's decrement — a weak
        // capture could leak activeStripCount high and suppress per-item
        // ghosts forever.
        AlphaFade.run(imageView, to: 0, duration: duration, controlPoints: controlPoints) { [window, self] in
            window.orderOut(nil)
            self.standDown()
        }
    }
}

/// Hands the first complete frame to one waiter, copied out of the
/// pixel buffer byte for byte, tagged with the buffer's own colour space
/// (the display profile) so it draws unmanaged, as the still did. Top-level
/// on purpose: nested in the @MainActor overlay it inherited the actor and
/// SCK's callback on the capture queue tripped the isolation check, and
/// the target's MainActor default isolation did the same for a top-level
/// class until `nonisolated`.
nonisolated private final class FirstFrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var pending: CGImage?
    private var done = false

    func firstImage(timeout: Duration) async -> CGImage? {
        await withCheckedContinuation { cont in
            lock.lock()
            if let pending {
                lock.unlock()
                cont.resume(returning: pending)
                return
            }
            continuation = cont
            lock.unlock()
            Task { try? await Task.sleep(for: timeout); self.finish(nil) }
        }
    }

    private func finish(_ image: CGImage?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        if let cont = continuation {
            done = true
            continuation = nil
            lock.unlock()
            cont.resume(returning: image)
        } else {
            if pending == nil { pending = image }
            lock.unlock()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete, status != .idle {
            return
        }
        finish(Self.cgImage(from: buffer))
    }

    private static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // The frame is tagged with the display's own profile ("Color LCD");
        // the picture must carry the same tag or AppKit matches it as
        // device/sRGB on the way to the window (+6 red, +4 blue, measured).
        let space = (CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil) as! CGColorSpace?)
            ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
