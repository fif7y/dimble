// MenuBarBandMonitor.swift
// Watches the menubar band on every display: hover dwell + empty-area clicks
// reveal; leaving the band / clicking elsewhere feeds the rehide machine.
// Also implements per-display behavior: the display the pointer is on wins.

import AppKit
import PelmetCore
import PelmetEngine

final class MenuBarBandMonitor {
    private weak var appState: AppState?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    /// The pointer feed: a CG tap that wakes the main thread only for moves
    /// the band cares about; the NSEvent monitors are its fallback.
    private var pointerTap: PointerMoveTap?
    private var clickMonitor: Any?
    private var dragMonitor: Any?
    private var hoverTimer: Timer?
    private var pointerInBand = false
    /// The hover reveal listens on the RIGHT half of the bar only: the left
    /// half is app menus, and a bar that opened while the pointer went for
    /// File or Edit pulled the eye to the far right for nothing (#21). The
    /// band as a whole still holds rehide off (`pointerInBand`).
    private var pointerInHoverZone = false
    private var cmdDragActive = false
    /// A ⌘-drag happened since the last adoption pass. Band-exit adoption is
    /// a catch-all for missed mouse-ups — but unconditionally snapshotting the
    /// AX tree on EVERY top-edge graze was the tax; only drags change layout.
    private var dragSinceAdoption = false
    /// A drop waiting for its adoption pass. The bar must stay revealed
    /// until then: a dropped item keeps its old section, and a conceal took
    /// it off the bar before adoption could read where it landed.
    private var dropAdoptionPending = false
    /// The app owning the status item under the last mouse-down, and the one
    /// the running ⌘-drag grabbed: the drop's adoption looks for its icon.
    private var lastHitOwner: String?
    private var dragOwner: String?
    /// A ⌘-drag that began while the panel was open can end on it
    /// (`BarDragRedirect`): where it began, and the panel's zone it was
    /// armed with (screen points).
    private let dragRedirect = BarDragRedirect()
    private var dragStart: NSPoint?
    private var dragItem: ItemID?
    private var panelDropZone: CGRect?
    /// The last left mouse-down (screen point, event time): only a drag
    /// pressed on the bar carries an icon, and a press after a drag began
    /// means that drag's mouse-up was missed.
    private var lastLeftDown: (point: NSPoint, at: TimeInterval)?
    private var dragPressedOnBar = false
    private var dragStartedAt: TimeInterval = 0
    private var localDownMonitor: Any?
    /// Set by a deliberate conceal (chevron / empty-area click) so the hover
    /// path can't undo it while the pointer is still where it clicked.
    private var hoverSuppressedUntilExit = false
    private var lastDisplayUUID: String?

    /// Per-screen geometry the mouse-move path reads on EVERY event, cached.
    /// `NSScreen.screens`, `visibleFrame`, the notch areas and the display
    /// UUID (a `deviceDescription` dictionary per call) each allocate or
    /// round-trip, and together they were about half of what a pointer
    /// move off the bar cost (perf audit 2026-10-02: 0.44ms and ~6 context
    /// switches a move, ~4% CPU under a moving mouse). Screens change
    /// rarely; the cache rebuilds on the notification.
    private struct ScreenGeometry {
        let screen: NSScreen
        let frame: NSRect
        /// The menu bar band, `.zero` on a screen with no bar.
        let band: NSRect
        /// The hardware cutout's open x span: nothing draws there, so it is
        /// never the bar (2026-09-12: a pointer crossing it on the way to
        /// Sconce's notch surface read as a bar hover).
        let notch: (minX: CGFloat, maxX: CGFloat)?
        let uuid: String?
    }
    private var screenGeometry: [ScreenGeometry] = []
    private var screenObserver: NSObjectProtocol?

    private func rebuildScreenGeometry(retryingMisses: Bool = true) {
        var missed = false
        screenGeometry = NSScreen.screens.map { screen in
            // Off the main display the visibleFrame keeps no band: the bar's
            // own window has its height (30pt on an external), and a display
            // with none drawn (Displays have separate Spaces off) has no band.
            let visibleBand = screen.frame.maxY - screen.visibleFrame.maxY
            let drawn = visibleBand > 0 ? nil : GlassPanel.drawnBarHeight(of: screen)
            if visibleBand <= 0, drawn == nil { missed = true }
            let bandHeight = visibleBand > 0 ? visibleBand : drawn ?? 0
            let band = bandHeight > 0
                ? NSRect(x: screen.frame.minX, y: screen.frame.maxY - bandHeight, width: screen.frame.width, height: bandHeight)
                : .zero
            var notch: (minX: CGFloat, maxX: CGFloat)?
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notch = (left.maxX, right.minX)
            }
            return ScreenGeometry(screen: screen, frame: screen.frame, band: band, notch: notch, uuid: screen.displayUUIDString)
        }
        pointerTap?.update(displays: screenGeometry.compactMap { geometry in
            guard let id = geometry.screen.directDisplayID else { return nil }
            let bounds = CGDisplayBounds(id)
            return PointerMoveTap.Display(bounds: bounds, bandMaxY: bounds.minY + geometry.band.height)
        })
        // A display's bar window can come a beat after the display: one more
        // look, or hover stayed off there until the screens next changed.
        if missed, retryingMisses {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.rebuildScreenGeometry(retryingMisses: false)
                let bands = self.screenGeometry.map { "\(Int($0.band.height))" }.joined(separator: ",")
                PelmetLog.log("band: a display had no bar drawn, read again — bands \(bands)pt")
            }
        }
    }

    private func screenGeometry(containing point: NSPoint) -> ScreenGeometry? {
        if screenGeometry.isEmpty { rebuildScreenGeometry() }
        return screenGeometry.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// `NSScreen` instances are stable between parameter changes, and the
    /// cache rebuilds on each, so identity finds the entry.
    private func geometry(of screen: NSScreen) -> ScreenGeometry? {
        if let found = screenGeometry.first(where: { $0.screen === screen }) { return found }
        rebuildScreenGeometry()
        return screenGeometry.first { $0.screen === screen }
    }

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        rebuildScreenGeometry()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildScreenGeometry() }
        }
        // Passive global monitors: enough for hover + click detection, no
        // event swallowing (empty-area clicks fall through harmlessly).
        let tap = PointerMoveTap { [weak self] in self?.pointerMoved() }
        if tap.start() {
            pointerTap = tap
            rebuildScreenGeometry()
        } else {
            PelmetLog.log("band: pointer tap unavailable — NSEvent monitors instead")
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                self?.pointerMoved()
            }
            // Global monitors never see the app's OWN events. While Pelmet is
            // the active app — after Settings or onboarding closes it stays
            // active with no window until the user clicks elsewhere — every
            // menubar mouseMoved is Pelmet's own, and hovers went blind
            // (2026-09-08: "the first few hovers after closing Settings do
            // nothing"). The tap sees its own process's events.
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                self?.pointerMoved()
                return event
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if event.type == .leftMouseDown { self?.lastLeftDown = (event.locationInWindow, event.timestamp) }
            self?.clicked(event)
        }
        // Presses on Pelmet's own items come to Pelmet, not the global monitor.
        localDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.lastLeftDown = (NSEvent.mouseLocation, event.timestamp)
            return event
        }
        // ⌘-drag tracking: rehide must never fire mid-drag, and adoption runs
        // the moment the drag ends — before the next conceal can act on a
        // stale model (which hid everything except the freshly dragged item).
        dragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.dragEvent(event)
        }
    }

    /// Accessibility arrived after `start`. A tap made before it comes up
    /// but sees only the pointer over Pelmet's own windows, so hover worked
    /// in Settings and nowhere else until the next launch (#116: an update
    /// relaunch started untrusted, the grant landed 45 s later). A fresh tap
    /// sees every move, and the NSEvent fallback gives way to it.
    func accessibilityGranted() {
        let tap = PointerMoveTap { [weak self] in self?.pointerMoved() }
        guard tap.start() else { return }
        pointerTap?.stop()
        pointerTap = tap
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        mouseMonitor = nil
        localMouseMonitor = nil
        rebuildScreenGeometry()
        PelmetLog.log("band: pointer tap restarted — Accessibility arrived")
    }

    private func dragEvent(_ event: NSEvent) {
        guard let appState else { return }
        switch event.type {
        case .leftMouseDragged:
            // A press since this drag began: its mouse-up never reached us.
            if cmdDragActive, let down = lastLeftDown, down.at > dragStartedAt {
                PelmetLog.log("band: ⌘-drag's mouse-up was missed, a new press ends it")
                cmdDragActive = false
                endPanelDrop(appState)
            }
            if cmdDragActive {
                // The panel a ⌘-drag opened arrives a beat after the drag.
                if panelDropZone == nil { armPanelDrop(appState) }
                if panelDropZone != nil {
                    // One read of the panel's drop zones per drag event.
                    let zone = appState.panelPresenter.barDrag(at: dragRedirect.realPointer() ?? event.locationInWindow).zone
                    if let zone, zone != panelDropZone {
                        panelDropZone = zone
                        dragRedirect.update(zone: zone)
                    }
                }
            }
            guard event.modifierFlags.contains(.command) else { return }
            // Pelmet's own synthetic drags reach this global monitor too —
            // adopting them is circular (model → drag → adopt → model), and
            // adopting a BOUNCED one would cement the failure into the model.
            guard !appState.syntheticDragInFlight else { return }
            // Where the event happened, not where the pointer is by the time
            // it is handled: a quick flick is past the band by then.
            let location = event.locationInWindow
            let screen = NSScreen.containing(location)
            guard let screen, isInMenuBarBand(location, of: screen) else { return }
            if !cmdDragActive {
                cmdDragActive = true
                dragSinceAdoption = true
                dragOwner = lastHitOwner
                appState.pointerReturnedToBand()  // cancels any rehide countdown
                PelmetLog.log("band: ⌘-drag started")
                dragStartedAt = event.timestamp
                dragStart = location
                // A window or a file dragged up into the bar carries no icon.
                dragPressedOnBar = lastLeftDown.map { down in
                    NSScreen.containing(down.point).map { isInMenuBarBand(down.point, of: $0) } == true
                } ?? false
                dragItem = appState.snapshot.flatMap { AppState.barItem(at: location, bundle: dragOwner, in: $0.items) }
                armPanelDrop(appState)
                // Nothing walks icons into the hidden run any more, so the
                // run must be on screen to be a drop target (or the panel, in
                // Panel mode). A deliberate reveal: the countdown re-arms at
                // the drop (below) and the band gate holds it while the
                // pointer is still up here.
                if !appState.sectionsRevealed {
                    appState.reveal([.hidden], reason: .barDrag)
                }
            }
        case .leftMouseUp:
            guard cmdDragActive else { return }
            cmdDragActive = false
            if panelDropZone != nil {
                let drop = dragRedirect.takeDrop()
                let section = drop.flatMap { $0.rewrote ? appState.panelPresenter.barDrag(at: $0.point).section : nil }
                endPanelDrop(appState)
                // The tap's word decides: it told macOS the icon went home,
                // or it didn't and macOS has the drop.
                if let drop, drop.rewrote {
                    PelmetLog.log("band: ⌘-drag let go on the panel at \(Int(drop.point.x)),\(Int(drop.point.y))")
                    dragSinceAdoption = false
                    if let section, let start = dragStart {
                        PelmetLog.log("band: ⌘-drag ended on the panel → \(section.rawValue) (from x=\(Int(start.x)), grabbed \(dragOwner ?? "unknown"))")
                        appState.barDropOnPanel(dragItem, at: start, bundle: dragOwner, section: section)
                    } else {
                        PelmetLog.log("band: ⌘-drag ended on the panel, nothing under it — back in its place")
                    }
                    if appState.isRevealed { appState.pointerLeftBand() }
                    return
                }
            } else {
                endPanelDrop(appState)
            }
            // The mouse-up was seen: the band-exit catch-all must not adopt
            // early without the drop x. MenuBarAgent's drag image under the
            // pointer reads as leaving the band right after the drop, and
            // that pass blamed the drag on Pelmet's own icon (2026-09-25).
            dragSinceAdoption = false
            dropAdoptionPending = true
            // The drop x identifies WHICH item was dragged (it lands under
            // the cursor) — chevron-less zone adoption needs that identity.
            // x is global (Cocoa and CG share it). The display under the drop
            // goes with it when it is not the main one: the walk keeps the
            // main display's copies, and Vorssaint dropped on the LG's bar
            // (x=4920) was matched against the built-in's (live test,
            // 2026-10-13 19:29:50). Where the event happened, as at the drag's
            // start: a flick across a display edge after the drop read the
            // other display's bar (review, 2026-10-13).
            let dropPoint = event.locationInWindow
            let dropX = dropPoint.x
            let dropDisplay = NSScreen.containing(dropPoint)?.directDisplayID
                .flatMap { $0 == CGMainDisplayID() ? nil : CGDisplayBounds($0) }
            let owner = dragOwner
            PelmetLog.log("band: ⌘-drag ended → adopting (dropX=\(Int(dropX)), grabbed \(owner ?? "unknown"))"
                + (dropDisplay.map { ", on the display at x=\(Int($0.minX))…\(Int($0.maxX))" } ?? ""))
            // Give MenuBarAgent a beat to finalize the new position, then
            // adopt before rehide can run a stale conceal.
            DispatchQueue.main.asyncAfter(deadline: .now() + AppTiming.dragAdoptDelay) { [weak self] in
                guard let self, let appState = self.appState else { return }
                self.dropAdoptionPending = false
                appState.adoptSectionsFromBar(dragEndX: dropX, dropDisplay: dropDisplay, draggedBundle: owner)
                if appState.isRevealed {
                    appState.pointerLeftBand()  // re-arm the countdown
                }
            }
        default:
            break
        }
    }

    /// Arms `BarDragRedirect` once the panel is open under a running ⌘-drag
    /// that was pressed on the bar.
    private func armPanelDrop(_ appState: AppState) {
        guard dragPressedOnBar, let start = dragStart, let zone = appState.panelPresenter.barDragZone(),
              dragRedirect.arm(zone: zone, anchor: start)
        else { return }
        panelDropZone = zone
        appState.panelPresenter.beginBarDrag(dragItem)
        PelmetLog.log("band: ⌘-drag can end on the panel (\(dragItem?.rawValue ?? "icon unknown"))")
    }

    private func endPanelDrop(_ appState: AppState) {
        // A drag that opened the panel marked it there, armed or not.
        appState.panelPresenter.endBarDrag()
        guard panelDropZone != nil else { return }
        dragRedirect.disarm()
        panelDropZone = nil
    }

    func stop() {
        pointerTap?.stop()
        pointerTap = nil
        dragRedirect.disarm()
        panelDropZone = nil
        if let localDownMonitor { NSEvent.removeMonitor(localDownMonitor) }
        localDownMonitor = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        localMouseMonitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        mouseMonitor = nil
        clickMonitor = nil
        dragMonitor = nil
        hoverTimer?.invalidate()
    }

    // MARK: - Pointer

    /// The launch applied the policy for the display under the pointer: it
    /// is the baseline, unless a move set one first. Unseeded, a conceal
    /// (⌥⌘,) before the first move was undone by its first twitch on an
    /// "always show all" display (review, 2026-10-13).
    func seedPointerDisplay() {
        guard lastDisplayUUID == nil else { return }
        lastDisplayUUID = screenGeometry(containing: NSEvent.mouseLocation)?.uuid
    }

    private func pointerMoved() {
        guard let appState else { return }
        let location = NSEvent.mouseLocation
        let geometry = screenGeometry(containing: location)
        let screen = geometry?.screen
        let inBand = geometry.map { isBarHover(location, of: $0) } ?? false
        let displayUUID = geometry?.uuid

        // Per-display behavior: crossing onto an "always show all" display
        // reveals; crossing back to a "collapse" display arms the countdown.
        // (An instant conceal here flashed the bar open-shut when the pointer
        // crossed displays right after a hover reveal — rehide, don't snap.)
        if displayUUID != lastDisplayUUID {
            // The first sighting (nil at launch) reveals on an "always show
            // all" display once the launch is done, and is a baseline
            // otherwise (`DisplayCrossing`, live test 2026-10-13).
            let action = DisplayCrossing.action(
                from: lastDisplayUUID, to: displayUUID,
                behavior: appState.settings.behavior(forDisplayUUID: displayUUID),
                launched: appState.launchBaselineApplied, revealed: appState.isRevealed,
                anchored: appState.transitions.anchored
            )
            lastDisplayUUID = displayUUID
            switch action {
            case .reveal:
                // Not .hover: a display-policy reveal must not inherit the
                // hover fast-rehide path, and the rehide timer defers
                // while the pointer stays on this display.
                appState.reveal([.hidden], reason: .displayPolicy)
            case .leaveBand:
                appState.pointerLeftBand()
            case .none:
                break
            }
        }

        guard appState.settings.behavior(forDisplayUUID: displayUUID) == .collapse else { return }

        if inBand, !pointerInBand {
            pointerInBand = true
            appState.pointerReturnedToBand()
            // The right half of the band is where reveals and clock clicks
            // come from: a dropped picture is retaken on the way in (#49,
            // #51: a straight approach to the clock never crosses the
            // hover zone, and every clock click captured live).
            if let screen, location.x >= screen.frame.midX {
                appState.pointerEnteredHoverZone()
                // A dwell here reveals nothing: name the edge, so a hover that
                // "did nothing" reads as a zone question in the log (#84).
                if !isHoverZone(location, of: screen) {
                    let edge = revealTriggerMaxX() ?? pinnedZoneMinX()
                    PelmetLog.log("band: entered past the hover zone at x=\(Int(location.x)) (edge \(edge.map { String(Int($0)) } ?? "none"))")
                }
            }
        } else if !inBand, pointerInBand {
            pointerInBand = false
            hoverSuppressedUntilExit = false
            // Leaving the band arms the countdown (never an instant conceal),
            // and catches a ⌘-drag whose mouse-up the monitor missed.
            appState.pointerLeftBand()
            // A drag on its way to the panel is still in the air, unless no
            // button is down: then its mouse-up may have been missed, and the
            // drag held the bar and the panel's drop open until the next
            // click. A beat first: this move came by the pointer tap and the
            // mouse-up comes by the monitor, in either order, and ending the
            // drag here lost a drop the mouse-up was about to file.
            if dragSinceAdoption, panelDropZone != nil, NSEvent.pressedMouseButtons & 1 == 0 {
                let started = dragStartedAt
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, let appState = self.appState, self.cmdDragActive, self.dragStartedAt == started,
                          self.panelDropZone != nil, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                    PelmetLog.log("band: ⌘-drag's mouse-up was missed on the way to the panel, leaving the bar ends it")
                    self.cmdDragActive = false
                    self.endPanelDrop(appState)
                    self.dragSinceAdoption = false
                    appState.adoptSectionsFromBar()
                }
            }
            if dragSinceAdoption, panelDropZone == nil {
                dragSinceAdoption = false
                appState.adoptSectionsFromBar()
            }
        }
        // The hover zone has its own edge: entering the band on the left and
        // sliding right still counts, leaving the zone drops the dwell.
        let inZone = inBand && screen.map { isHoverZone(location, of: $0) } == true
        if inZone, !pointerInHoverZone {
            pointerInHoverZone = true
            PelmetLog.log("band: hover zone entered at x=\(Int(location.x)) (mid \(Int(screen?.frame.midX ?? -1)))")
            appState.pointerEnteredHoverZone()
            // A synthetic placement warps the pointer through the band — a
            // hover reveal mid-drag injects a reveal/conceal cycle under the
            // running drag (frames shift mid-measurement; seen live during
            // the first overflow rescue). Not a hover.
            scheduleHoverReveal()
        } else if !inZone, pointerInHoverZone {
            pointerInHoverZone = false
            hoverTimer?.invalidate()
        }
    }

    /// Where a dwell opens the bar: the band, right of the screen's middle,
    /// up to the chevron (#37, 2026-09-19: a pointer parked on the clock to
    /// read it, on its way to Notification Center, or resting on a visible
    /// icon is not asking for the hidden icons — only the chevron and the
    /// strip left of it are).
    private func isHoverZone(_ point: NSPoint, of screen: NSScreen) -> Bool {
        point.x >= screen.frame.midX && !isPastRevealTriggerZone(point, on: screen)
    }

    /// Why rehide holds off: pointer in the band, Pelmet's own editor or
    /// onboarding in front, or a menubar-anchored menu/popover under the
    /// pointer. Nil when nothing holds. One window list per verdict: the
    /// old Bool + diagnostic-twin pair walked the list twice per deferred
    /// reveal (perf audit 2026-09-15, fix 4b).
    enum DeferReason: String { case band, active, elevated, drag, overflow }

    func rehideDeferReason() -> DeferReason? {
        if pointerInBand { return .band }
        if cmdDragActive || dropAdoptionPending || appState?.dropAdoptionInFlight == true { return .drag }
        // Pelmet frontmost only holds the bar for the layout editor and the
        // onboarding demo — the General tab is not a reason to stay revealed.
        if NSApp.isActive, appState?.editorHoldsBar == true || OnboardingController.shared.isPresented { return .active }
        if pointerIsOverElevatedWindow() { return .elevated }
        // Apple's « open on hidden icons that didn't fit: it draws them left
        // of the notch, and the notch is off the band, so the way there read
        // as leaving the bar and they concealed under the pointer (#81, live
        // test 2026-10-19). Held while the pointer crosses the notch only: a
        // « left open must not hold the reveal once the pointer is off the
        // bar, and its icons, drawn, no longer read as behind it.
        if let appState, appState.isRevealed, pointerOnNotch(),
           OverflowToggle.isExpanded() == true { return .overflow }
        // A chevron click on a display that shows all icons opens Always
        // Hidden there (#96): held while the pointer stays on that bar, as
        // on a hiding one. `pointerInBand` never tracks such a display, it
        // reveals nothing on hover (live, 2026-10-20: concealed 0.8s in).
        if let appState, appState.isRevealed, pointerOnShowAllBar(appState) { return .band }
        return nil
    }

    private func pointerOnShowAllBar(_ appState: AppState) -> Bool {
        let location = NSEvent.mouseLocation
        guard let geometry = screenGeometry(containing: location) else { return false }
        return appState.settings.behavior(forDisplayUUID: geometry.uuid) == .alwaysShowAll
            && NSMouseInRect(location, geometry.band, false)
    }

    private func pointerOnNotch() -> Bool {
        let location = NSEvent.mouseLocation
        guard let geometry = screenGeometry(containing: location), let notch = geometry.notch else { return false }
        return NSMouseInRect(location, geometry.band, false) && location.x > notch.minX && location.x < notch.maxX
    }

    /// Deliberately narrow: only visible, menu/popover-sized windows at
    /// elevated levels count. `layer > 0` alone matches the invisible
    /// always-on-top helper windows half the utilities on a Mac keep around
    /// (PopClip, Unclutter, Raycast…) — that overreach made rehide never fire.
    private func pointerIsOverElevatedWindow() -> Bool {
        let location = NSEvent.mouseLocation
        guard
            let primary = NSScreen.screens.first,
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return false }
        // CG window bounds are top-left-origin global coordinates.
        let cgPoint = CGPoint(x: location.x, y: primary.frame.maxY - location.y)
        // Menus and popovers hang BELOW the bar. Anything whose top edge sits
        // in or above the band is a host/overlay window, not something the
        // user opened: Control Center keeps a 656×973 layer-101 window at
        // y=0 and Sconce a 640×538 layer-25 overlay at y=-40 — both passed
        // the size filter and pinned every hover-out reveal open (2026-09-02).
        let bandHeight = primary.frame.maxY - primary.visibleFrame.maxY
        for window in windows {
            guard
                let layer = window[kCGWindowLayer as String] as? Int,
                // Status-item popovers and menus live in this level range;
                // floating utility panels (level 3) and the Dock (20) don't count.
                layer >= 24, layer <= 102,
                let alpha = window[kCGWindowAlpha as String] as? CGFloat, alpha > 0.05,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"],
                let width = bounds["Width"], let height = bounds["Height"],
                // Menu/popover-sized, not screen-covering overlays.
                width < 900, height < 1200, width > 4, height > 4,
                y >= bandHeight - 1
            else { continue }
            if CGRect(x: x, y: y, width: width, height: height).contains(cgPoint) {
                return true
            }
        }
        return false
    }

    /// Pointer state for the settle catch-up: a reveal that outlives its hover
    /// re-arms on the short clock.
    var pointerCurrentlyInBand: Bool { pointerInBand }

    private func scheduleHoverReveal() {
        guard let appState,
              appState.settings.revealTriggers.hoverEnabled, !appState.isRevealed, appState.itemsInBar.isEmpty else { return }
        guard !appState.syntheticDragInFlight, !hoverSuppressedUntilExit else {
            PelmetLog.log("band: hover refused — \(hoverSuppressedUntilExit ? "concealed under the pointer, waits for it to leave the bar" : "synthetic drag in flight")")
            return
        }
        // Floor: otherwise the bar flaps open on the way to a hot corner.
        let delay = max(appState.settings.revealTriggers.hoverDelay, AppTiming.hoverDelayFloor)
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState, self.pointerInHoverZone, appState.itemsInBar.isEmpty else { return }
                PerfTrace.markTrigger("hover")
                // Re-verify against the LIVE pointer, not just the
                // tracked flag — the flag lags by one event-delivery
                // latency, which is exactly a fast swipe-through. A
                // graze must not open the bar.
                let location = NSEvent.mouseLocation
                guard let geometry = self.screenGeometry(containing: location),
                      self.isBarHover(location, of: geometry),
                      self.isHoverZone(location, of: geometry.screen),
                      !appState.syntheticDragInFlight else {
                    PelmetLog.log("band: hover dropped at the dwell's end, pointer at x=\(Int(location.x)) y=\(Int(location.y))")
                    return
                }
                appState.reveal([.hidden], reason: .hover)
            }
        }
    }

    /// Conceal-settle self-heal (mirror of the reveal-side one): a rapid
    /// hover out-in can put the pointer back in the band while a conceal is
    /// mid-flight — the entry edge is already spent, so without this the bar
    /// stays shut under a hovering pointer until it leaves and re-enters.
    func suppressHoverUntilPointerLeaves() {
        // Only a pointer on the bar can reopen what was just concealed, and
        // only leaving the bar clears the flag: set from the shortcut with
        // the pointer elsewhere, it ate the next hover visit whole (#84).
        guard pointerInBand else { return }
        hoverSuppressedUntilExit = true
        hoverTimer?.invalidate()
    }

    func rearmHoverAfterConceal() {
        guard pointerInHoverZone,
              let appState,
              appState.settings.behavior(
                forDisplayUUID: NSScreen.containing(NSEvent.mouseLocation)?.displayUUIDString
              ) == .collapse
        else { return }
        scheduleHoverReveal()
    }

    /// A single click on a revealed bar, held for the double-click interval
    /// so a double's first click can't collapse what its second reopens.
    private var pendingConceal: Task<Void, Never>?
    private var acceptedClickSequence = AcceptedClickSequence()

    private func clicked(_ event: NSEvent) {
        guard let appState else { return }
        let location = NSEvent.mouseLocation
        let screen = NSScreen.containing(location)
        let inBand = screen.map { isInMenuBarBand(location, of: $0) } ?? false

        // Every path out of here that is not an accepted empty-bar click
        // breaks the sequence — the refusals below, a right-click, a click
        // outside the band. Done once, on the way out, so a refusal added
        // later cannot forget to do it.
        var accepted = false
        defer { if !accepted { acceptedClickSequence.reset() } }

        if inBand {
            // Synthetic placement drags post real ⌘-mouse-downs in the band —
            // the hit-test can read one as an empty-area click (a trapped
            // item's phantom position has no element under it) and toggle a
            // reveal under the running drag (seen live during rescue).
            // The item menu relay's click on an icon behind an open « reads
            // the same way: it opened the panel over the menu it was
            // opening, "showed nothing" (#81, CleanMyMac, twice). Only the
            // relay's own click: refusing every click while a relay ran left
            // the empty bar dead for as long as what it opened stayed up
            // (up to a minute for an app's window).
            guard !appState.syntheticDragInFlight else { return }
            if let own = ownPostedClick(event) {
                PelmetLog.log("band: click refused — Pelmet's own posted click (\(own))")
                return
            }
            // The icons a relay's open « exposed hit-test as empty bar too:
            // a click on one is that icon's, never a reveal over its menu.
            if ItemPress.holdsOverflowOpen {
                PelmetLog.log("band: click refused — a press relay holds the « open")
                return
            }
            // Stamped before the gates so the perf line counts the
            // hit-test IPCs a click pays on its way to `dispatch`.
            PerfTrace.markTrigger("click")
            // The window-server hit-test is the arbiter for clicks too. On
            // its own `isEmptyMenuBarArea` reads any foreign AXWindow/AXGroup
            // — and a nil hit — as empty bar, so a right-click on an app that
            // draws its own surface across the band opened Pelmet's settings
            // menu over that app's own menu (issue #8). This is the gate the
            // hover path got on 2026-09-07; the click path never received it.
            // Refusing here is a no-op, not a rehide: these monitors are
            // passive, so the click reaches the app that owns the window.
            if let screen, let overlay = foreignOverlay(under: location, of: screen) {
                PelmetLog.log("band: click refused — on \(overlay)")
                return
            }
            if let screen, isInPinnedRightZone(location, on: screen) {
                PelmetLog.log("band: click refused — on Control Center, the clock or right of them")
                return
            }
            guard isEmptyMenuBarArea(location, on: screen) else { return }
            if event.type == .rightMouseDown {
                // Right-click on empty bar: the settings entry that survives a
                // hidden icon. Opt-out for bars shared with an app that wants
                // the same click (#8) — a separator's right-click is
                // unaffected, so turning this off keeps a way in.
                guard appState.settings.barRightClickMenuActive else { return }
                let menu = PelmetStatusItem.contextMenu(appState: appState)
                menu.popUp(positioning: nil, at: location, in: nil)
                return
            }
            guard appState.settings.revealTriggers.clickEnabled else { return }
            // Empty bar between visible icons is not a summons either:
            // the trigger zone ends at the chevron (see isHoverZone).
            if let screen, isPastRevealTriggerZone(location, on: screen) {
                PelmetLog.log("band: click refused — right of the chevron")
                return
            }
            accepted = true
            let acceptedCount = acceptedClickSequence.accept(
                rawCount: event.clickCount,
                timestamp: event.timestamp,
                doubleClickInterval: NSEvent.doubleClickInterval
            )
            PelmetLog.log("band: empty-area click raw=\(event.clickCount) accepted=\(acceptedCount)")
            if acceptedCount >= 2 {
                // Second click of a double: the deferred conceal (below) is
                // moot. With the feature off, ignore the click — acting
                // again reads as an open-shut flash.
                pendingConceal?.cancel()
                pendingConceal = nil
                if appState.settings.revealTriggers.doubleClickForAlwaysHidden {
                    appState.reveal([.hidden, .alwaysHidden], reason: .doubleClick)
                }
            } else if appState.sectionsRevealed, appState.settings.revealTriggers.doubleClickForAlwaysHidden {
                // Revealed bar (hover got there first, the usual case): a
                // plain click conceals, but a double's FIRST click landed
                // here too and collapsed the bar 170ms before the second
                // click reopened it wider — a choppy shut-then-open flash
                // (2026-09-05). Hold the conceal for the system's
                // double-click interval; a second click cancels it. Only the
                // dismiss waits — summoning below stays instant.
                pendingConceal?.cancel()
                let interval = NSEvent.doubleClickInterval
                pendingConceal = Task { @MainActor [weak appState] in
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled, let appState, appState.sectionsRevealed else { return }
                    PelmetLog.log("band: deferred single-click conceal fired")
                    appState.toggle(reason: .click)
                }
            } else {
                // Concealed bar: a single click acts IMMEDIATELY — the old
                // 300ms double-click defer made every plain click feel dead.
                // A double's second click widens the reveal on top
                // (revealRequested unions), so no defer is needed here.
                appState.toggle(reason: .click)
            }
        } else if appState.isRevealed {
            // Clicks inside Pelmet's own UI or a status-item menu/popover are
            // part of using the revealed items — and while the settings window
            // is open nothing collapses, period. Clicks on an "always show"
            // display never collapse either: the display's policy wins.
            if !appState.editorHoldsBar, !NSApp.isActive, !pointerIsOverElevatedWindow(),
               appState.settings.behavior(forDisplayUUID: screen?.displayUUIDString) == .collapse {
                appState.rehideTriggered(.clickedElsewhere)
            }
        }
    }

    /// How long after Pelmet posts a shielded click a click is taken for it,
    /// should a monitor's copy of the event come without the tag.
    private static let ownClickWindow: TimeInterval = 0.25

    /// Why `event` is a click Pelmet posted itself (the press relay's, the
    /// « toggle's, the clock's replay), nil for the user's. Pelmet's sources
    /// tag their events (`SyntheticInput.tag`); a shielded click (the relay's
    /// and the « toggle's) is also known by its time.
    private func ownPostedClick(_ event: NSEvent) -> String? {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SyntheticInput.tag { return "tagged" }
        guard let posted = SyntheticInput.clickPostedAt else { return nil }
        let after = event.timestamp - posted
        guard after > -0.05, after < Self.ownClickWindow else { return nil }
        return "untagged, \(Int(after * 1000))ms after a shielded click"
    }

    // MARK: - Geometry

    /// In the band AND on the bar itself. A pointer resting on another app's
    /// window that straddles the band — Sconce's notch surface (640×542 at
    /// y=-44, 2026-09-07) — is that app's hover, not ours: hovering the notch
    /// to open Sconce revealed the hidden section a beat later, which read as
    /// the bar "going blank and re-rendering". The window-server hit-test is
    /// the arbiter (it honours ignoresMouseEvents, so Sconce's transparent
    /// canvas margins still count as bar; a geometric containment check
    /// would not, and would also catch Control Center's host window across
    /// the top-right quadrant). Thin strips (Unclutter's 2pt trigger) and the
    /// menubar host window itself never exceed the band's height.
    private func isBarHover(_ point: NSPoint, of geometry: ScreenGeometry) -> Bool {
        guard isInMenuBarBand(point, of: geometry) else { return false }
        let screen = geometry.screen
        let overlay = foreignOverlay(under: point, of: screen)
        if overlay != lastForeignOverlay {
            lastForeignOverlay = overlay
            PelmetLog.log("band: pointer \(overlay.map { "on \($0)" } ?? "off any") overlay at (\(Int(point.x)),\(Int(screen.frame.maxY - point.y)))")
        }
        return overlay == nil
    }

    private var lastForeignOverlay: String?
    /// The last window-info verdict, keyed by window number. The hit-test
    /// IPC still runs on every move so a new window under the pointer is
    /// seen at once; only the window-info fetch for the SAME window is
    /// skipped for 250ms (perf audit 2026-09-15, fix 4a: the two IPCs were
    /// half the in-band per-move cost). A live resize across the
    /// band-height threshold is the one thing the TTL bounds.
    private var overlayVerdict: (number: Int, verdict: String?, takenAt: TimeInterval)?

    /// Owner + size of another process's tall window under the point, or nil
    /// when the hit is the bar (or one of our own covers / ghosts).
    private func foreignOverlay(under point: NSPoint, of screen: NSScreen) -> String? {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0 else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = overlayVerdict, cached.number == number, now - cached.takenAt < 0.25 {
            return cached.verdict
        }
        let verdict = foreignOverlayVerdict(windowNumber: number, of: screen)
        overlayVerdict = (number, verdict, now)
        return verdict
    }

    private func foreignOverlayVerdict(windowNumber number: Int, of screen: NSScreen) -> String? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let window = windows.first,
              let pid = window[kCGWindowOwnerPID as String] as? Int32,
              pid != ProcessInfo.processInfo.processIdentifier,
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
              let height = bounds["Height"], let width = bounds["Width"], let y = bounds["Y"]
        else { return nil }
        // The band as cached: an external's visibleFrame keeps none, and any
        // window under the pointer there, the bar's own, would be taller.
        let bandHeight = geometry(of: screen)?.band.height ?? (screen.frame.maxY - screen.visibleFrame.maxY)
        guard height > bandHeight + 1 else { return nil }
        // Below desktop level nothing can be occluding the bar. The hit-test
        // intermittently resolves to Finder's wallpaper window on an external
        // display (`Finder 3440×1440@y-164 L-2147483603`, 13 times in one
        // session) — harmless on the hover path, which re-reads on the next
        // mouseMoved, but a click has no next event and would be swallowed.
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        guard layer >= 0 else { return nil }
        let owner = window[kCGWindowOwnerName as String] as? String ?? "pid \(pid)"
        return "\(owner) \(Int(width))×\(Int(height))@y\(Int(y)) L\(layer)"
    }

    private func isInMenuBarBand(_ point: NSPoint, of screen: NSScreen) -> Bool {
        guard let geometry = geometry(of: screen) else { return false }
        return isInMenuBarBand(point, of: geometry)
    }

    private func isInMenuBarBand(_ point: NSPoint, of geometry: ScreenGeometry) -> Bool {
        guard geometry.band.height > 0, NSMouseInRect(point, geometry.band, false) else { return false }
        if let notch = geometry.notch, point.x > notch.minX, point.x < notch.maxX { return false }
        return true
    }

    /// Empty = the AX element under the pointer belongs to the menubar host
    /// but is not an item/menu. A systemwide hit-test works on every display
    /// (the snapshot's frames are main-display-only, which silently broke
    /// empty-click detection on external screens).
    /// macOS 27 parks the privacy indicator — the purple dot — at the far
    /// right of the bar, past the clock. It draws no AX element of its own,
    /// so `isEmptyMenuBarArea` reads it as bare bar and a click aimed at the
    /// clock that lands a few points wide summoned the hidden icons instead
    /// (reported 2026-09-17). Nothing of Pelmet's is reachable right of the
    /// clock, so the whole zone is out of bounds for the click trigger.
    /// The clock and Control Center themselves are out of bounds too (#37,
    /// 2026-09-19): macOS pins both, nothing of Pelmet's can sit on them,
    /// and a click there mid-reflow (the clock relay drops the assertion
    /// right before it replays the click) can hit-test as the agent's bare
    /// backdrop and summon the hidden icons — so the zone starts at the
    /// leftmost of the two, not at the clock's right edge.
    /// Mirrored per display by right-edge inset, the way ClockClickRelay
    /// does it: the bar repeats on every screen at the same inset, while the
    /// walk only ever hands back the main display's copy of the pair.
    /// Neither in the walk (locked screen, empty AX) is no rule.
    private func isInPinnedRightZone(_ point: NSPoint, on screen: NSScreen) -> Bool {
        guard let zoneMinX = pinnedZoneMinX() else { return false }
        return isAtOrRight(of: zoneMinX, point, on: screen)
    }

    /// The reveal triggers (hover dwell, empty-area click) work on the
    /// strip up to and including the chevron — the middle of the screen to
    /// Pelmet's icon, where the hidden icons land. Everything right of the
    /// icon — the visible section, the system items, Control Center, the
    /// clock — is a place the user goes for its own sake (Gab, 2026-09-19);
    /// the icon's click toggles through its own button. The icon was left
    /// out of the hover zone at first; with the chevron on, a hover that
    /// stops on the icon itself and reveals nothing read as broken (Gab,
    /// 2026-09-20). With the chevron switched off the bound is the visible
    /// section's leftmost live icon, and with nothing in Visible either it
    /// falls back to the pinned pair.
    private func isPastRevealTriggerZone(_ point: NSPoint, on screen: NSScreen) -> Bool {
        // The chevron behind Apple's « on a display that reveals in the bar:
        // the bar has no room for the hidden icons either, and a hover by the
        // notch only flickered them behind the « (#81, live test). A panel
        // or a row still opens from the zone.
        if let appState, appState.chevronTrapToggle != nil,
           appState.settings.revealTarget(forDisplayUUID: screen.displayUUIDString) == .menuBar { return true }
        guard let bound = revealTriggerMaxX() ?? pinnedZoneMinX() else { return false }
        return isAtOrRight(of: bound, point, on: screen)
    }

    /// Main-display x past which the reveal triggers stop: the chevron's
    /// right edge, else the leftmost live icon assigned to Visible.
    private func revealTriggerMaxX() -> CGFloat? {
        // Behind Apple's « the chevron's window stays parked on the «, which
        // put the « inside the zone: a hover there revealed every hidden icon
        // straight behind it (#81). The triggers stop short of it, a pointer
        // resting 1pt left of its frame on the way in still revealed.
        if let toggle = appState?.chevronTrapToggle {
            // A global x: as a main-display x, the way `liveChevronMaxX`
            // reads the chevron (review, 2026-10-19).
            let x = toggle.minX - 8
            guard let geometry = screenGeometry.first(where: { x >= $0.frame.minX && x < $0.frame.maxX }),
                  let primary = screenGeometry.first else { return x }
            return primary.frame.maxX - (geometry.frame.maxX - x)
        }
        guard let appState, let items = appState.snapshot?.items,
              let primaryMaxX = NSScreen.screens.first?.frame.maxX else { return nil }
        let live = items.compactMap { item -> (id: ItemID, frame: CGRect)? in
            guard let frame = item.frame, MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX) else { return nil }
            return (item.id, frame)
        }
        let walked = live.first(where: { MenuBarPolicy.isChevronID($0.id, pelmetBundleID: PelmetBundle.mainID) })?.frame.maxX
        // The chevron's own window first: right after a swap the snapshot
        // still holds the other layout's frames, and a hover resting by the
        // chevron read as past the zone (#84).
        if let drawn = liveChevronMaxX() {
            noteEdgeMismatch(drawn: drawn, walked: walked)
            return drawn
        }
        if let walked { return walked }
        let model = appState.settings.sectionModel
        return live.filter { model.section(of: $0.id) == .visible }.map(\.frame.minX).min()
    }

    /// The drawn chevron's right edge as a main-display x (the bar repeats
    /// on every screen at the same right inset), nil when it isn't in a
    /// screen's band (icon off, not placed yet). Behind Apple's « it stays
    /// in the band, parked on the « (#81).
    /// On the per-move path: the screens come from the cache, the main
    /// display first as in `NSScreen.screens`.
    private func liveChevronMaxX() -> CGFloat? {
        guard let frame = appState?.chevronWindowFrame,
              let geometry = screenGeometry(containing: NSPoint(x: frame.midX, y: frame.midY)),
              let primary = screenGeometry.first,
              geometry.band.intersects(frame) else { return nil }
        return primary.frame.maxX - (geometry.frame.maxX - frame.maxX)
    }

    private var lastEdgeMismatch: String?
    /// One line each time the drawn and walked edges start or stop
    /// disagreeing: how stale the snapshot's chevron gets, live.
    private func noteEdgeMismatch(drawn: CGFloat, walked: CGFloat?) {
        let note = walked.flatMap { abs($0 - drawn) > 4 ? "drawn \(Int(drawn)) vs walked \(Int($0))" : nil }
        guard note != lastEdgeMismatch else { return }
        lastEdgeMismatch = note
        if let note { PelmetLog.log("band: chevron edge \(note)") }
    }

    /// Main-display x where Control Center / the clock begin (the leftmost
    /// of the two that is in the walk), nil when neither is.
    private func pinnedZoneMinX() -> CGFloat? {
        guard let primary = NSScreen.screens.first, let items = appState?.snapshot?.items else { return nil }
        let primaryMaxX = primary.frame.maxX
        return items.compactMap { item -> CGFloat? in
            guard item.id.rawValue.hasSuffix("::com.apple.menuextra.clock")
                    || item.id.rawValue.hasSuffix("::com.apple.menuextra.controlcenter"),
                  let frame = item.frame, MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX)
            else { return nil }
            return frame.minX
        }.min()
    }

    /// A main-display bound mirrored onto `screen` by right-edge inset, the
    /// way ClockClickRelay does it: the bar repeats on every screen at the
    /// same inset, while the walk only ever hands back the main copy.
    private func isAtOrRight(of mainX: CGFloat, _ point: NSPoint, on screen: NSScreen) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let insetFromRight = primary.frame.maxX - mainX
        return point.x >= screen.frame.maxX - insetFromRight
    }

    private func isEmptyMenuBarArea(_ point: NSPoint, on screen: NSScreen?) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        // Convert bottom-left mouse coords → top-left AX coords.
        let axPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &element) == .success,
              let element else {
            // Nothing under the pointer at all — treat as empty bar.
            return true
        }
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
        // Items, buttons, and app menus are NOT empty; the agent's bare
        // window/group backdrop is.
        let itemRoles: Set<String> = ["AXMenuBarItem", "AXButton", "AXMenuButton", "AXImage"]
        // Pelmet's OWN extras bar under the pointer is one of its items,
        // not empty space: right after the chevron moved (a capture shifts
        // the bar 3pt, a conceal reflows it) the item's AX frame lags and
        // the hit lands on the bar element that holds it. Reading that as
        // an empty-area click toggled a reveal, the button's own action
        // then queued the opposite, and the pointer's hover reopened the
        // bar — a click that flashed open-shut-open (16 times across two
        // logs, 2026-09-18).
        if role == "AXMenuBar", pid == ProcessInfo.processInfo.processIdentifier, Self.isOwnExtrasBar(element) {
            PelmetLog.log("band: hit-test role=AXMenuBar owner=\(owner) → own extras bar, not empty")
            return false
        }
        // The frontmost app's bare AXMenuBar element is the backdrop that
        // spans the whole bar — hitting it (not an AXMenuBarItem title) means
        // empty space. The agent's own window/group backdrop counts too.
        let empty = !itemRoles.contains(role)
            && (role == "AXMenuBar"
                || owner == PelmetBundle.agentID
                || role == "AXWindow" || role == "AXGroup")
        lastHitOwner = role == "AXMenuBarItem" && owner != "?" ? owner : nil
        PelmetLog.log("band: hit-test role=\(role) owner=\(owner) → empty=\(empty)")
        return empty
    }

    /// The element is Pelmet's `AXExtrasMenuBar` (its status items' bar),
    /// as opposed to its app menu bar, which only spans the bar while a
    /// Pelmet window is frontmost.
    private static func isOwnExtrasBar(_ element: AXUIElement) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        // Not frontmost: Pelmet has no app menu bar on screen, so its only
        // AXMenuBar under the pointer is the extras bar.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != me { return true }
        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(me), "AXExtrasMenuBar" as CFString, &extras) == .success,
              let extras else { return false }
        return CFEqual(extras, element)
    }

}
