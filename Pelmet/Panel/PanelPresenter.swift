// PanelPresenter.swift
// The hidden icons as tiles in a glass panel under the chevron, instead of
// on the bar (docs/PANEL-PLAN.md §5 Phase 3). The bar stays concealed the
// whole time: the rehide machine says revealed, this draws it. A tile click
// closes the panel through the machine and opens the item's menu the way
// ⌥⌘K does (ItemPress: alone, under a cover).
//
// Pictures: hidden icons are never drawn on the bar in this mode, so the
// first open with tiles missing one runs the picture pass (decision D2);
// app icons stand in until it lands.

import AppKit
import PelmetCore
import PelmetEngine
import ScreenCaptureKit
import SwiftUI

@MainActor
final class PanelPresenter: RevealPresenter {
    static let cornerRadius: CGFloat = 20
    /// The mock hangs the panel 6pt under the bar and 6pt past the
    /// chevron's right edge.
    static let gapBelowBar: CGFloat = 6
    static let pastChevron: CGFloat = 6

    private weak var appState: AppState?
    let pictures = ItemPictures()
    private var window: KeyableGlassPanel?
    private var hosting: PanelHostingView?
    /// The tracking area's owner, which it does not keep.
    private var pointerWatch: PointerWatch?
    private var gripHost: GripHostingView?
    /// The grip shows faintly while the pointer is on the panel.
    private var pointerOnPanel = false
    /// The columns are being dragged: the pointer runs ahead of the edge,
    /// off the panel, and that must not close it.
    private var draggingColumns = false
    /// The mouse-up that ends a column drag, seen directly: SwiftUI drops a
    /// gesture on a key press and never reports its end.
    private var columnMonitors: [Any] = []
    /// A column count was set during a drag and not saved yet: saving is
    /// `settingsChanged`, which re-syncs the chevron, extras and hotkeys,
    /// so it runs once, at the let-go.
    private var columnsUnsaved = false
    /// A tile is in the air (`TileDrag`): the pointer runs over the bar and
    /// off the panel, and that must not close it.
    private var tileDrag: TileDrag?
    /// A bar icon's copy while a ⌘-drag from the bar is over the panel.
    private var barGhost: PanelDragGhost?
    private var dragTimer: Timer?
    private var springTask: Task<Void, Never>?
    /// Esc during a drag: global (a panel a hover opened isn't key and hears
    /// no keys) and local, so a quick tap is not missed between two polls.
    private var escMonitors: [Any] = []
    /// What the drag shows, shared with the view.
    private let dragState = PanelDragState()
    /// Where SwiftUI laid out the sections, grids and fold, in the hosting
    /// view's space; read when the pointer needs a target.
    private var frames: [PanelFrameKey: CGRect] = [:]
    /// Bumped when one of `frames` moves, and per refresh: a drag tick with
    /// both and the pointer as they were has nothing new to read.
    private var framesSeen = 0
    private var draws = 0
    /// The button under a tile fires on the mouse-up that ends a drag too:
    /// no press until this passes (it starts at the release, not at the
    /// cancel).
    private var pressGuardUntil: CFTimeInterval = 0
    /// A drag was cancelled, or refused, with the button still down: the rest
    /// of that press is neither a drag nor a click. Ends at the release (or
    /// the next press).
    private var ignoresDragUntilRelease = false
    /// Mouse down and up, watched from a drag until its button comes up, so a
    /// release SwiftUI never reports (it drops a gesture on a key press) still
    /// ends it.
    private var mouseMonitors: [Any] = []
    /// The Esc that cancelled a drag, or its repeats, still reaches the
    /// panel's own key handler; that must not close the panel.
    private var escSwallowUntil: CFTimeInterval = 0
    private(set) var isOpen = false
    private var openedByHover = false
    /// The display it opened on, kept until it closes: a refresh (a key, a
    /// fold, a picture pass) never moves it to another one.
    private var openScreen: CGDirectDisplayID?
    /// Opened by the pointer on a bar (a hover, a click, a ⌘-drag), not by
    /// a key or Settings: the pointer's display is the one (`targetScreen`).
    private var openedAtBar = false
    /// A display unplugged or rearranged while it is open.
    private var screenObserver: NSObjectProtocol?
    /// Windows built again because the window server had the panel off the
    /// active Space (#100).
    private var spaceRebuilds = 0
    /// Held like a menu until the pointer is on the panel: opened from the
    /// keyboard, or reshaped by its column grip (a drag let go past the
    /// edge, or a reset that shrinks the panel from under the pointer,
    /// would otherwise close it).
    private var awaitsPointer = false
    /// When `place` last changed the window's frame.
    private var resizedAt: CFTimeInterval = 0
    private var sections: Set<PelmetCore.Section> = []
    /// Always Hidden's fold, for this open.
    private var foldOpen = false
    /// The keyboard's filter and selection, for this open.
    private var query = ""
    private var selected: PanelTile?
    /// Set when the query changed: the best match becomes the selection.
    private var selectBest = false
    /// The command bar's candidates for the items and launchers, read once
    /// per open: the filter ranks with them (aliases, synonyms), and they
    /// name the launchers.
    private var corpus: [CommandBarEntry] = []
    /// Each item's app, from `corpus`: a tile's menu looks it up.
    private var corpusApps: [ItemID: ItemMenuActions.ItemApp] = [:]
    /// Whether `corpus` was read at all, for the preview to read it once.
    private var corpusRead = false
    private var history = SearchHistory()
    /// What the last refresh drew, for Return and the arrows.
    private var lastModel: PanelModel?
    private var lastContent: PanelContent?
    /// Whether the panel last scrolled or wrapped, as logged.
    private var loggedFit: String?
    /// Each open from closed: a scrolled panel opens at the top again.
    private var opens = 0
    /// The grip's tip, and the wait before it goes.
    private var columnsTip: String?
    private var tipTask: Task<Void, Never>?
    private var keyMonitor: Any?
    /// The first key typed with the pointer on a hover-opened panel, swallowed
    /// before the app in front has it; armed only while such a panel is up.
    private lazy var typingTap = HoverTypingTap { [weak self] typed in self?.typedOverHoverPanel(typed) }
    private var typingGrace: Task<Void, Never>?
    /// Waiting on the pass under way, the preview's redraw among them.
    private var passWaiters: [@MainActor () -> Void] = []
    private var motion: Motion?
    private var motionTimer: Timer?
    /// Set by a fold: the next `place` moves the glass in this style.
    private var foldMotion: RevealAnimation?
    private var glassTimer: Timer?
    /// Where `place` last put the window, before any motion.
    private var placed: NSRect?
    /// The open `placed` belongs to (`generation`).
    private var placedGeneration = -1
    private var passTask: Task<Void, Never>?
    /// Keys a pass looked for and could not picture (an item that draws
    /// nothing, one the notch hides): not asked for again until a picture
    /// would have gone stale anyway.
    private var unpicturable: [ItemID: Date] = [:]
    /// `ConcealGhostOverlay.surfaceSignature()` when `unpicturable` was last
    /// cleared. A tile the pass tried and missed waits out `maxAge` before it
    /// is tried again, which is right while the bar it failed against is the
    /// same bar. A new wallpaper, or a light/dark switch, is a different bar:
    /// whatever refused the column is gone with it, so the wait goes too and
    /// the tile has its picture back on the next open instead of in a quarter
    /// of an hour. The signature is the backdrop watch's own, read here
    /// rather than observed, since nothing needs it until a pass is weighed.
    private var unpicturableSurface: [Int] = []
    /// Icons a pass revealed their section for and never found listed:
    /// their app runs with its own icon off, and the bar shows nothing for
    /// them (CleanShot, #26). Left out of the panel until the bar lists them
    /// again, and asked about again by the next pass that runs anyway.
    private var noIcon: Set<ItemID> = []
    /// Keys a pass was asked for because their app's extras bar disagreed
    /// with `noIcon`, and what that bar said (true: an icon listed).
    private var extrasSaid: [ItemID: Bool] = [:]
    /// Bundles whose extras bar a pass proved wrong: it says nothing about
    /// their icon, and is not asked again this launch.
    private var extrasSayNothing: Set<String> = []
    /// Bundles whose extras bar listed an icon this launch: only theirs is
    /// believed when it lists none. Velja's, Pure Paste's and Unclutter's
    /// list none with their icon on the bar (live, 2026-10-13).
    private var extrasListed: Set<String> = []
    /// Apps whose tile `noIcon` left out that came to the front since the
    /// last check: switching an icon back on is done in the app.
    private var inFrontSinceCheck: Set<String> = []
    /// When a pass last looked for each key `noIcon` left out.
    private var lookedFor: [ItemID: Date] = [:]
    /// How long after a look an app in front is looked at again: a second,
    /// doubled by every look that finds its icon still off (60s at most),
    /// a second again once it comes to the front anew. A fixed 10s missed
    /// a re-tick made right after the tile left (Gab, 2026-10-14).
    private var revisitAfter: [String: TimeInterval] = [:]
    private var activationObserver: NSObjectProtocol?
    private var iconCheck: Task<Void, Never>?
    /// Keys a pass of this open already asked for: one it got no picture of
    /// without trying (no cover, a skipped round) is asked for again next
    /// open, not by a pass straight after, which with no cover deferred the
    /// same keys again and again (review B5). Emptied when the panel closes.
    private var askedThisOpen: Set<ItemID> = []
    private var askedAgainLogged = false
    /// Bumped per open and close, so a fade that ends late leaves alone a
    /// panel that opened again.
    private var generation = 0
    /// What measures the panel, kept for an open: a refresh gives it a new
    /// root view instead of building a controller per pass.
    private var measurer: NSHostingController<PanelView>?
    /// The measuring pass has no drag to show, and must not watch the live one.
    private let idleDrag = PanelDragState()
    /// A redraw for the place a drag now aims at is queued (`reshuffle`).
    private var reshuffleTask: Task<Void, Never>?
    /// Tiles ease into their places until then: while a drag makes room, and
    /// a moment after it ends, as a cancelled one returns.
    private var easeUntil: CFTimeInterval = 0

    init(appState: AppState) {
        self.appState = appState
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let bundle, self.noIcon.contains(where: { $0.bundleID == bundle }) else { return }
                self.inFrontSinceCheck.insert(bundle)
            }
        }
    }

    /// Whether an armed rehide should wait. The panel closes as the bar
    /// does, once the pointer leaves (Gab, 2026-10-09: a clicked one held
    /// like a menu and read as stuck), so it holds while the pointer is on
    /// it or between it and the bar: the gap under the bar is crossed on
    /// the way in, and with no rehide delay the countdown ran out right
    /// there. A shortcut's panel holds until the pointer has been on it,
    /// as the bar does for a shortcut's reveal.
    ///
    /// The menu bar counts by its rectangle, not by what the band monitor
    /// saw: a picture pass covers the bar with a window of its own, the
    /// monitor read the pointer as gone and a clicked panel closed 0.3s in
    /// (2026-10-09).
    var holdsReveal: Bool {
        guard isOpen, let window else { return false }
        if awaitsPointer || draggingColumns || tileDrag != nil { return true }
        let pointer = NSEvent.mouseLocation
        var reach = window.frame
        if let screen = window.screen ?? NSScreen.main {
            reach.size.height = screen.frame.maxY - reach.minY
            // NSMouseInRect: a pointer pushed to the top row sits at maxY,
            // which `contains` leaves out.
            if NSMouseInRect(pointer, Self.barBand(of: screen), false) { return true }
        }
        if NSMouseInRect(pointer, reach, false) { return true }
        PelmetLog.log("panel: let go — pointer at \(Int(pointer.x)),\(Int(pointer.y)), panel \(Int(reach.minX))…\(Int(reach.maxX))")
        return false
    }

    private var showsGrip = false

    private func updateGrip() {
        gripHost?.rootView = PanelEdgeGrip(
            shows: showsGrip, panelHovered: pointerOnPanel,
            onDrag: { [weak self] _, ended in self?.dragColumns(ended: ended) },
            onReset: { [weak self] in self?.resetColumns() })
    }

    /// Off the panel is off the bar: the countdown starts at the rehide
    /// delay, not at the next re-arm a second and a half on. Not when the
    /// panel shrank out from under a pointer that stayed put: a filter
    /// typed with the pointer resting on it would close it mid-word.
    private func pointerLeftPanel() {
        guard isOpen, !awaitsPointer, !draggingColumns, tileDrag == nil, CACurrentMediaTime() - resizedAt > 0.1 else { return }
        PelmetLog.log("panel: pointer left")
        appState?.pointerLeftBand()
    }

    // MARK: - RevealPresenter

    func reveal(_ sections: Set<PelmetCore.Section>, reason: RevealReason?, trace: PerfTrace) {
        let wasOpen = isOpen
        // A click on a hover-opened panel makes it deliberate; a hover never
        // turns a deliberate one back.
        openedByHover = reason == .hover && (!wasOpen || openedByHover)
        self.sections = sections
        if !wasOpen {
            awaitsPointer = reason == .hotkey
            // Where the reveal was decided (#88): that display's choice
            // brought the panel, so it opens there.
            openScreen = appState?.revealDecision?.display
            openedAtBar = reason.map(RevealRouting.startsAtBar) ?? false
            foldOpen = false
            query = ""
            selected = nil
            opens += 1
            if let appState { loadCorpus(appState) }
        }
        isOpen = true
        generation += 1
        let shown = refresh()
        trace.mark("built", detail: "\(shown.tiles) tiles")
        show(takeKey: !openedByHover, fadeIn: !wasOpen)
        // On screen from the next pass of the run loop: the `perf` line's
        // open → first frame.
        DispatchQueue.main.async { trace.finish("shown") }
        // A kept picture (one from the last launch, #104) draws while the
        // pass retakes it; a tile with none draws its app's icon.
        let bare = lastContent?.art.filter { entry in
            if case .item = entry.key, case .icon = entry.value.image { return true }
            return false
        }.count ?? 0
        PelmetLog.log("panel: \(wasOpen ? "widened" : "open") (\(reason.map { "\($0)" } ?? "no reason")) — \(shown.tiles) tile(s), \(shown.missing.count) without a fresh picture (\(bare) with none), key=\(window?.isKeyWindow == true)")
        // Settled on the next turn, as the bar's reveal settles after its
        // effect returns: the machine is still in this dispatch.
        DispatchQueue.main.async { [weak self] in self?.appState?.panelDidSettle() }
        if reason == .barDrag { barDragging = true }
        picturePassUnlessBarDrag(shown.missing)
        if !wasOpen, !barDragging { checkIconsGone() }
    }

    func conceal(trace: PerfTrace) {
        close()
        trace.finish("closed")
        DispatchQueue.main.async { [weak self] in self?.appState?.panelDidSettle() }
    }

    /// Off screen with no settle of its own: the bar is taking over the
    /// reveal that is under way.
    func dismiss() {
        close()
    }

    /// A click or a key on a panel a hover opened, asking for what is
    /// already out: the machine has nothing to reveal, but the panel is the
    /// click's now, taking keys.
    func makeDeliberate() {
        guard isOpen, openedByHover else { return }
        openedByHover = false
        disarmTyping()
        window?.makeKey()
        installKeyMonitor()
        PelmetLog.log("panel: made deliberate, key=\(window?.isKeyWindow == true)")
    }

    // MARK: - Typing over a hover panel

    /// Where the typing tap listens: the glass at rest, in screen points.
    private var glassZone: NSRect? {
        guard let window, let placed else { return nil }
        return NSRect(x: placed.minX + window.leadingMargin, y: placed.minY,
                      width: placed.width - window.leadingMargin, height: placed.height)
    }

    private func armTyping() {
        guard isOpen, openedByHover, let zone = glassZone else { return }
        typingTap.arm(zone: zone, window: window)
    }

    private func updateTypingZone() {
        guard openedByHover, let zone = glassZone else { return }
        typingTap.update(zone: zone)
    }

    private func disarmTyping() {
        typingGrace?.cancel()
        typingGrace = nil
        typingTap.disarm()
    }

    /// The tap swallowed the first printable key typed with the pointer on
    /// the panel: the panel is the typist's now, and the search starts with it.
    private func typedOverHoverPanel(_ typed: String) {
        guard isOpen else { return }
        if openedByHover {
            makeDeliberate()
            PelmetLog.log("panel: typed over the hover panel, search \"\(typed)\"")
            // The window server may not have moved focus here yet: for a
            // moment longer the tap keeps the keys that follow, in order.
            if let zone = glassZone, typingTap.arm(zone: zone, window: window, keepingPresses: true) {
                typingGrace = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, !Task.isCancelled else { return }
                    self.typingGrace = nil
                    self.typingTap.disarm()
                }
            }
        }
        guard let new = PanelKey.query(query, typing: typed) else { return }
        setQuery(new)
    }

    /// A panel drop's Apply is over and its cover is off the bar: the tiles
    /// it moved may have no picture yet, taken now from a bar nothing covers
    /// (the pass itself never films, `holdBarForApply` holds the bar).
    /// "Didn't fit" as the bar was before a pass: mid-Apply the whole bar is
    /// out at once and its walks put a full bar's worth behind the «.
    private var didntFitAtRest: [ItemID] = []

    private func didntFit(_ appState: AppState) -> [ItemID] {
        if !appState.applying { didntFitAtRest = appState.overflowTrappedItems }
        return didntFitAtRest
    }

    func quietApplyEnded() {
        guard isOpen, tileDrag == nil else { return }
        let shown = refresh()
        picturePassIfNeeded(shown.missing)
    }

    // MARK: - Window

    private func ensureWindow() -> (KeyableGlassPanel, PanelHostingView) {
        if let window, let hosting { return (window, hosting) }
        let hosting = PanelHostingView(rootView: Self.blank())
        // The window's frame is ours; the content must not resize it.
        hosting.sizingOptions = []
        let window = KeyableGlassPanel(content: hosting, cornerRadius: Self.cornerRadius)
        window.alphaValue = 0
        // Dev: `pelmet.debug.panelOneSpace` keeps the first window to one
        // Space, to check the rebuild in `show` (#100): open the panel once,
        // switch Space, open it there.
        if spaceRebuilds == 0, UserDefaults.standard.bool(forKey: "pelmet.debug.panelOneSpace") {
            window.collectionBehavior.remove(.canJoinAllSpaces)
        }
        // A display unplugged, the lid closed, a scale changed: place it
        // again (on another display if its own is gone).
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                PelmetLog.log("panel: screens changed, placing again")
                self.refresh()
            }
        }
        // The column grip sits half past the glass's left edge, in a clear
        // margin of the window (`show` sets the window to take clicks on
        // its clear parts too).
        window.leadingMargin = ColumnGrip.reach / 2
        let grip = GripHostingView(rootView: PanelEdgeGrip())
        grip.sizingOptions = []
        window.edgeAccessory = grip
        gripHost = grip
        let watch = PointerWatch(
            entered: { [weak self] in
                self?.awaitsPointer = false
                self?.pointerOnPanel = true
                self?.updateGrip()
            },
            exited: { [weak self] in
                guard let self else { return }
                // Leaving counts as having been on it, unless the panel
                // just reshaped away from the pointer.
                if CACurrentMediaTime() - self.resizedAt > 0.1 { self.awaitsPointer = false }
                self.pointerOnPanel = false
                self.updateGrip()
                self.pointerLeftPanel()
            })
        window.contentView?.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: watch, userInfo: nil))
        pointerWatch = watch
        self.window = window
        self.hosting = hosting
        return (window, hosting)
    }

    private func show(takeKey: Bool, fadeIn: Bool) {
        guard var window else { return }
        present(window, fadeIn: fadeIn)
        // The window joins every Space, yet one Mac had the panel open on
        // one Space only (#100, not seen on 27.2): ordered in off the active
        // Space, it is built again, once per show.
        if !window.isOnActiveSpace, let rebuilt = rebuildOffSpace(window) {
            window = rebuilt
            present(window, fadeIn: fadeIn)
            PelmetLog.log("panel: built again, \(window.isOnActiveSpace ? "on" : "still off") the active Space")
        }
        // Keys only for a panel opened on purpose: a hover passing by must
        // not take the typing from the app in front.
        if takeKey {
            disarmTyping()
            window.makeKey()
            installKeyMonitor()
        } else {
            armTyping()
        }
    }

    private func present(_ window: KeyableGlassPanel, fadeIn: Bool) {
        window.ignoresMouseEvents = false
        // Dev: `pelmet.debug.panelAppearance` light or dark checks the other
        // mode without changing the Mac's. Read at each open.
        window.appearance = switch UserDefaults.standard.string(forKey: "pelmet.debug.panelAppearance") {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        if fadeIn {
            window.alphaValue = 0
            move(Self.reduceMotion ? nil : Motion(
                duration: AppTiming.panelEntrance, from: AppTiming.panelEntranceDrop, to: 0, curve: HouseEasing.enterCurve))
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AppTiming.panelEntrance
                context.timingFunction = HouseEasing.enterTiming
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
    }

    /// Logs where the window server has `old`, then drops it for a new
    /// window with the same content and place.
    private func rebuildOffSpace(_ old: KeyableGlassPanel) -> KeyableGlassPanel? {
        PelmetLog.log("panel: window \(old.windowNumber) off the active Space (\(Self.spaces(of: old)), behavior \(old.collectionBehavior.rawValue)), building it again")
        old.orderOut(nil)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        window = nil
        hosting = nil
        spaceRebuilds += 1
        refresh()
        return window
    }

    /// The Spaces the window server has `window` on, and the active one, for
    /// the log (private CGS, resolved via dlsym like the mover's).
    private static func spaces(of window: NSWindow) -> String {
        typealias Connection = @convention(c) () -> Int32
        typealias Active = @convention(c) (Int32) -> UInt64
        typealias Spaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connectionSym = dlsym(rtldDefault, "CGSMainConnectionID"),
              let activeSym = dlsym(rtldDefault, "CGSGetActiveSpace"),
              let spacesSym = dlsym(rtldDefault, "SLSCopySpacesForWindows") ?? dlsym(rtldDefault, "CGSCopySpacesForWindows")
        else { return "Spaces unreadable" }
        let cid = unsafeBitCast(connectionSym, to: Connection.self)()
        let active = unsafeBitCast(activeSym, to: Active.self)(cid)
        // 7: every Space the window is on, shown or not.
        let on = unsafeBitCast(spacesSym, to: Spaces.self)(cid, 7, [window.windowNumber] as CFArray)?
            .takeRetainedValue() as? [Int] ?? []
        return "on \(on.isEmpty ? "no Space" : on.map(String.init).joined(separator: ", ")), active \(active)"
    }

    private func close() {
        guard isOpen else { return }
        if tileDrag != nil { finishDrag(cancel: true, closing: true) }
        isOpen = false
        pointerOnPanel = false
        askedThisOpen = []
        askedAgainLogged = false
        // A column drag cut short saves where it got to; its tip goes with
        // the panel, not into the next open.
        if draggingColumns { endColumnDrag() }
        tipTask?.cancel()
        tipTask = nil
        columnsTip = nil
        barDragging = false
        generation += 1
        let mine = generation
        removeKeyMonitor()
        disarmTyping()
        PelmetLog.log("panel: closed")
        guard let window else { return }
        // A fold under way stops where it is: its end would place the
        // window mid-fade, a jump.
        stopGlass()
        foldMotion = nil
        // Up for the length of its fade: a click on it must not land, and a
        // click beneath it must.
        window.ignoresMouseEvents = true
        move(Self.reduceMotion ? nil : Motion(
            duration: AppTiming.panelExit, from: 0, to: AppTiming.panelExitRise, curve: HouseEasing.exitCurve))
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = AppTiming.panelExit
            context.timingFunction = HouseEasing.exitTiming
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit calls this on the main thread but does not say so.
            Task { @MainActor in
                guard let self, self.generation == mine, !self.isOpen else { return }
                self.window?.orderOut(nil)
                // Hidden, not gone: a search row left in the window would
                // keep its caret blinking on a timer of its own.
                self.query = ""
                self.hosting?.rootView = Self.blank()
                self.measurer = nil
            }
        })
    }

    /// A panel with nothing in it: what the window holds before the first
    /// open and after each close.
    private static func blank() -> PanelHost {
        PanelHost(panel: PanelView(content: PanelContent(), onPress: { _ in }, onFold: {}))
    }

    // MARK: - Motion

    /// Reduce Motion: Smooth's slide becomes a fade.
    private static func foldStyle(_ style: RevealAnimation) -> RevealAnimation {
        style == .smooth && reduceMotion ? .fade : style
    }

    /// Always Hidden's fold, in the Animation style: the window takes the
    /// taller height for the length of it, its top where it is, and the
    /// glass inside grows or shrinks with the tiles (Smooth), or holds while
    /// they fade out (Fade). A fade in has the glass at its height at once.
    private func resizeGlass(to frame: NSRect, style: RevealAnimation) {
        guard let window else { return }
        stopGlass()
        let from = window.glassHeight
        let to = frame.height
        let growing = to >= from
        let duration: TimeInterval = switch style {
        case .instant: 0
        case .smooth: growing ? AppTiming.smoothRevealDuration : AppTiming.smoothExitDuration
        case .fade: growing ? 0 : AppTiming.fadeExitDuration
        }
        guard duration > 0, from != to else {
            placed = frame
            window.place(frame, glassHeight: to)
            return
        }
        let tall = NSRect(x: frame.minX, y: frame.maxY - max(from, to), width: frame.width, height: max(from, to))
        placed = tall
        window.place(tall, glassHeight: from)
        let timer: Timer
        if style == .fade {
            // The glass holds while the tiles fade: nothing to step, so one
            // timer for the end.
            timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishGlass(frame: frame, height: to) }
            }
        } else {
            let curve = growing ? HouseEasing.enterCurve : HouseEasing.exitCurve
            let start = CACurrentMediaTime()
            timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    let t = min((CACurrentMediaTime() - start) / duration, 1)
                    guard t < 1 else {
                        self.finishGlass(frame: frame, height: to)
                        return
                    }
                    window.setGlassHeight(from + (to - from) * curve.value(at: t))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        glassTimer = timer
    }

    /// The end of a fold: the window at the frame the panel settles on, the
    /// glass at its height.
    private func finishGlass(frame: NSRect, height: CGFloat) {
        guard let window else { return }
        stopGlass()
        resizedAt = CACurrentMediaTime()
        placed = frame
        window.place(frame, glassHeight: height)
        updateTypingZone()
    }

    private func stopGlass() {
        glassTimer?.invalidate()
        glassTimer = nil
    }

    /// The mock's entrance drop or exit rise, stepped by hand over where
    /// `place` last put the window: a refresh mid-motion (a key typed right
    /// after the hotkey) moves that spot, and the motion follows it. An
    /// animator frame animation would put back the frame it started with.
    private struct Motion {
        let start = CACurrentMediaTime()
        let duration: TimeInterval
        let from: CGFloat
        let to: CGFloat
        let curve: UnitCurve

        func offset(at now: CFTimeInterval) -> CGFloat {
            let t = min(max((now - start) / duration, 0), 1)
            return from + (to - from) * curve.value(at: t)
        }
    }

    /// Reduce Motion keeps the fades and drops the travel.
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func move(_ motion: Motion?) {
        motionTimer?.invalidate()
        motionTimer = nil
        self.motion = motion
        stepMotion()
        guard motion != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepMotion() }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func stepMotion() {
        guard let window, let placed else { return }
        let now = CACurrentMediaTime()
        window.setFrameOrigin(NSPoint(x: placed.minX, y: placed.minY + (motion?.offset(at: now) ?? 0)))
        if let motion, now - motion.start >= motion.duration {
            motionTimer?.invalidate()
            motionTimer = nil
            self.motion = nil
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, event.window === self.window else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
    }

    /// The mock's keys: type to filter, arrows and Return, Esc clears the
    /// filter and then closes. True when the key was the panel's.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let key = PanelKey(event) else { return false }
        switch key {
        case .escape:
            if tileDrag != nil {
                cancelDrag()
            } else if CACurrentMediaTime() < escSwallowUntil {
                // The Esc that just cancelled a drag, or a repeat of it.
                escSwallowUntil = CACurrentMediaTime() + 0.3
            } else if query.isEmpty {
                appState?.concealNow()
            } else {
                setQuery("")
            }
        case .enter:
            if let tile = selected ?? lastModel?.bestMatch { press(tile) }
        case .move(let direction):
            guard let content = lastContent else { break }
            switch content.step(from: selected, toward: direction) {
            case .select(let tile): select(tile, in: content)
            case .unfold: toggleFold()
            case .stay: break
            }
        case .delete:
            if !query.isEmpty { setQuery(String(query.dropLast())) }
        case .type(let typed):
            guard let new = PanelKey.query(query, typing: typed) else { return false }
            setQuery(new)
        }
        return true
    }

    /// An arrow moved the selection. The tiles, the size and the window are
    /// as the last refresh left them, so only the highlight is drawn again.
    /// The view scrolls to the new selection on its own.
    private func select(_ tile: PanelTile, in drawn: PanelContent) {
        selected = tile
        // A tile the panel doesn't show has no place to be selected: the
        // refresh clears it. A fold under way ends in the refresh's place.
        guard glassTimer == nil, let hosting, drawn.art[tile] != nil || tile == .fold else {
            refresh()
            return
        }
        var content = drawn
        content.selected = tile
        lastContent = content
        hosting.rootView = PanelHost(panel: view(content))
    }

    private func setQuery(_ new: String) {
        query = new
        selectBest = true
        refresh()
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Right-aligned under the bar, its right edge just past the chevron
    /// (the display's edge less a margin when the icon is off). It opens on
    /// the display under the pointer; the chevron's distance from its
    /// display's right edge carries over, as the bar lays out the same on
    /// every display.
    private func place(_ size: CGSize) {
        guard let window, let target = targetScreen() else { return }
        defer { updateTypingZone() }
        let margin = GlassPanel.edgeMargin
        var right = target.frame.maxX - margin
        if let chevron = drawnChevron() {
            right = min(right, target.frame.maxX - (chevron.screen.frame.maxX - chevron.frame.maxX) + Self.pastChevron)
        }
        let width = min(size.width, target.frame.width - 2 * margin)
        let top = Self.top(on: target)
        // The glass's frame, then the window's: wider by the grip's margin.
        let glassX = max(right - width, target.frame.minX + margin).rounded()
        let frame = NSRect(
            x: glassX - window.leadingMargin,
            y: (top - size.height).rounded(),
            width: width.rounded() + window.leadingMargin, height: size.height.rounded())
        if frame.size != placed?.size { resizedAt = CACurrentMediaTime() }
        // The oracle for a panel that moves under the pointer (#104): a
        // resize within one open, as pictures landing on 34pt tiles made.
        if isOpen, placedGeneration == generation, let before = placed, before.size != frame.size {
            PelmetLog.log("panel: \(Int(before.width))×\(Int(before.height)) → \(Int(frame.width))×\(Int(frame.height)), left edge \(Int(before.minX)) → \(Int(frame.minX))")
        }
        placedGeneration = generation
        if let style = foldMotion {
            foldMotion = nil
            resizeGlass(to: frame, style: style)
            return
        }
        stopGlass()
        placed = frame
        window.place(frame.offsetBy(dx: 0, dy: motion?.offset(at: CACurrentMediaTime()) ?? 0), glassHeight: frame.height)
    }

    /// The display the panel opens on, and keeps until it closes: the one
    /// the reveal was decided on (`AppState.decidingScreen`), the pointer's.
    /// The chevron's button window lives on one display while every bar
    /// draws a copy of it, so the chevron's display put a click, Show All or
    /// ⌘-drag on another display's bar on that one (as AppKit does the
    /// chevron's menu, #26). A shortcut or Settings can come with the
    /// pointer anywhere: its display only when a bar is drawn there, or the
    /// panel hung under no bar, over an app (Displays have separate Spaces
    /// off, an app full screen); the active display's or the primary if not.
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let id = openScreen, let kept = screens.first(where: { $0.directDisplayID == id }) { return kept }
        let target = appState?.decidingScreen(atBar: openedAtBar) ?? screens.first
        openScreen = target?.directDisplayID
        if let target {
            let from = target == NSScreen.underPointer ? "the pointer's" : "no bar under the pointer, the active or primary"
            PelmetLog.log("panel: on display \(openScreen.map(String.init) ?? "?") (\(from)), bar \(Int(GlassPanel.barHeight(of: target)))pt")
        }
        return target
    }

    /// Panel or Row, as the display it opened on picked it (kept until it
    /// closes, `AppState.revealDecision`).
    private var layout: PanelGrid.Layout {
        appState?.revealDecision?.target.panelLayout ?? appState?.revealTarget.panelLayout ?? .panel
    }

    /// The chevron and its display, nil when it isn't in a bar's band (icon
    /// off, not placed yet): a parked frame would place the panel by nothing
    /// on screen. Behind Apple's « the frame stays in the band, parked on
    /// the «, and the panel opens under the « (#81). The band is the bar's
    /// own height (`GlassPanel.barBand`), 30pt on an external display.
    private func drawnChevron() -> (frame: NSRect, screen: NSScreen)? {
        guard let frame = appState?.chevronWindowFrame else { return nil }
        let mid = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mid, $0.frame, false) }) else { return nil }
        return Self.barBand(of: screen).intersects(frame) ? (frame, screen) : nil
    }

    /// The menu bar across `screen`.
    private static func barBand(of screen: NSScreen) -> NSRect {
        GlassPanel.barBand(of: screen)
    }

    private static func top(on screen: NSScreen) -> CGFloat {
        screen.frame.maxY - GlassPanel.barHeight(of: screen) - gapBelowBar
    }

    /// As tall as the panel can be on `screen`: down to the Dock, or the
    /// display's bottom, less the edge margin.
    private static func heightCap(on screen: NSScreen) -> CGFloat {
        min(top(on: screen) - screen.visibleFrame.minY - GlassPanel.edgeMargin, debugCap)
    }

    /// Debug: `open -a Pelmet --args -pelmet.debug.panelCap 300` caps the
    /// height and the row's width as a short, narrow display would.
    private static var debugCap: CGFloat {
        let cap = UserDefaults.standard.double(forKey: "pelmet.debug.panelCap")
        return cap > 0 ? cap : .greatestFiniteMagnitude
    }

    // MARK: - Content

    /// Rebuilds the tiles and fits the window to them. Returns how many
    /// tiles it drew and which items have no picture yet.
    @discardableResult
    private func refresh() -> (tiles: Int, missing: [ItemID]) {
        guard let appState else { return (0, []) }
        let (_, hosting) = ensureWindow()
        draws &+= 1
        let screen = targetScreen()
        // The row wraps where `place` would cut it: the display less its
        // margins and the row's padding.
        let rowWidth = screen.map {
            min($0.frame.width - 2 * GlassPanel.edgeMargin, Self.debugCap) - 2 * PanelMetrics.row.padding
        }
        let aimed = tileDrag.flatMap { drag in drag.slot.map { (tile: drag.tile, slot: $0) } }
        let (built, missing, model) = buildContent(
            appState, layout: layout, query: query, selected: selected,
            foldOpen: foldOpen, alwaysRequested: sections.contains(.alwaysHidden), maxRowWidth: rowWidth, aimed: aimed)
        var content = built
        lastModel = model
        // What this draw shows of the drag; its frames are not final until the
        // tiles have eased there.
        if let drag = tileDrag {
            drag.shownSlot = drag.slot
            drag.settledAt = CACurrentMediaTime() + Self.makeRoomSettle
        }
        content.animatesTiles = (tileDrag != nil || CACurrentMediaTime() < easeUntil) && !Self.reduceMotion
        if selectBest {
            selectBest = false
            selected = query.isEmpty ? nil : model.bestMatch
            content.selected = selected.flatMap { content.art[$0] == nil ? nil : $0 }
        }
        // A filter or a fold can take the selected tile away.
        selected = content.selected
        content.columnsTip = columnsTip
        content.scrollID = opens
        // The hosting view sizes nothing (`sizingOptions = []`), so its
        // fitting size is zero: the view measures itself here. Taller than
        // the display, the tiles scroll in what the search row leaves.
        var size = measure(content)
        if let screen, size.height > Self.heightCap(on: screen) {
            let cap = Self.heightCap(on: screen)
            // With no room for the tiles, what is left is the search row and
            // its padding; the tiles then take the rest of the cap.
            content.scrollHeight = 0
            let rest = measure(content)
            content.scrollHeight = max(cap - rest.height, 0)
            size = CGSize(width: rest.width, height: max(cap, rest.height))
        }
        // The oracle for a short or narrow display: logged when it changes.
        let lines = content.layout == .row ? content.blocks.first?.grid.rows.count ?? 0 : 0
        let fit = "scrolls \(content.scrollHeight.map { "in \(Int($0))" } ?? "no")\(lines > 1 ? ", row wraps to \(lines)" : "")"
        if fit != loggedFit {
            loggedFit = fit
            PelmetLog.log("panel: \(Int(size.width))×\(Int(size.height)), \(fit)")
        }
        lastContent = content
        hosting.rootView = PanelHost(panel: view(content))
        showsGrip = content.layout == .panel && !content.isEmpty
        updateGrip()
        place(size)
        return (content.art.count, missing)
    }

    /// `live` is the panel on screen. The measuring pass has no drag, reports
    /// no frames and needs no menus, which would be built for every tile.
    private func view(_ content: PanelContent, live: Bool = true) -> PanelView {
        guard live else {
            return PanelView(content: content, onPress: { _ in }, onFold: {}, drawsGrip: false, drag: idleDrag)
        }
        return PanelView(
            content: content,
            onPress: { [weak self] tile in
                // The mouse-up that ends a drag is not a click.
                guard let self, self.tileDrag == nil, !self.ignoresDragUntilRelease,
                      CACurrentMediaTime() >= self.pressGuardUntil else { return }
                self.press(tile)
            },
            onFold: { [weak self] in self?.toggleFold() },
            // Same two steps as the menu's own row: the panel goes away
            // before Settings takes the focus.
            onSettings: { [weak self] in
                self?.appState?.concealNow()
                self?.appState?.openSettings(tab: .panel)
            },
            tileMenu: { [weak self] tile in self?.menu(for: tile) ?? [] },
            panelMenu: { [weak self] in
                self?.panelMenu(shown: self?.lastContent, onPanel: true) { [weak self] in self?.toggleFold() } ?? []
            },
            // The grip is the window's own (`updateGrip`), not the view's.
            drawsGrip: false,
            onTileDrag: { [weak self] tile, phase in self?.tileDragged(tile, phase) },
            drag: dragState,
            onFrame: { [weak self] key, frame in
                guard let self, self.frames[key] != frame else { return }
                self.frames[key] = frame
                self.framesSeen &+= 1
            })
    }

    private func measure(_ content: PanelContent) -> CGSize {
        let measured = view(content, live: false)
        let controller: NSHostingController<PanelView>
        if let measurer {
            measurer.rootView = measured
            controller = measurer
        } else {
            controller = NSHostingController(rootView: measured)
            measurer = controller
        }
        return controller.sizeThatFits(in: NSSize(width: 4000, height: 4000))
    }

    /// The command bar's candidates afresh, as an open reads them: the
    /// Settings preview shows the apps that are running now.
    func readCorpus() {
        guard let appState, !isOpen else { return }
        loadCorpus(appState)
    }

    /// The one read of the candidates and the search history, for an open
    /// and for the preview.
    private func loadCorpus(_ appState: AppState) {
        corpus = CommandBarCorpus.buildForPanel(appState: appState)
        // An item's first entry speaks for it, app or none.
        corpusApps = [:]
        var seen = Set<ItemID>()
        for entry in corpus {
            guard case .item(let id) = entry.action, seen.insert(id).inserted else { continue }
            if let app = entry.app { corpusApps[id] = app }
        }
        corpusRead = true
        history = CommandBarController.loadHistory()
    }

    typealias Preview = (content: PanelContent, missing: [ItemID], model: PanelModel)

    /// The panel as it would open now, for the Settings preview: its own
    /// filter, selection and fold.
    func previewContent(layout: PanelGrid.Layout, query: String, selected: PanelTile?, foldOpen: Bool) -> Preview? {
        guard let appState else { return nil }
        readCorpusOnce(appState)
        let built = buildContent(appState, layout: layout, query: query, selected: selected,
                                 foldOpen: foldOpen, alwaysRequested: false)
        return (built.content, built.missing, built.model)
    }

    /// What the preview's selection becomes when `query` is typed: the model
    /// ranks it, and no tile is laid out for the answer.
    func previewBestMatch(query: String) -> PanelTile? {
        guard let appState else { return nil }
        readCorpusOnce(appState)
        return buildModel(appState, query: query, alwaysRequested: false).model.bestMatch
    }

    private func readCorpusOnce(_ appState: AppState) {
        guard !corpusRead else { return }
        loadCorpus(appState)
    }

    /// Who is in the panel and in which section, for `query`; `items` are the
    /// bar's items it was made from.
    private func buildModel(_ appState: AppState, query: String, alwaysRequested: Bool)
        -> (model: PanelModel, items: [ObservedItem])
    {
        let options = appState.settings.panel
        // The editor's board, as Search reads it: live items, the concealed
        // ones that left the AX tree (the walk's `concealed` alone misses
        // system items such as Sound) and Pelmet's own extras, less those
        // the bar would not draw either.
        // An app that quit takes the verdict with it: relaunched, it is
        // looked for again.
        if !noIcon.isEmpty {
            noIcon = noIcon.filter { key in
                key.bundleID.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? true
            }
        }
        let listed = noIcon.isEmpty ? [] : Set((appState.snapshot?.items ?? []).map(\.id.sectionKey))
        let items = [PelmetCore.Section.hidden, .alwaysHidden, .visible].flatMap(appState.editorItems(in:))
            .filter { appState.ownExtraWouldShow($0.id) }
            .filter { !noIcon.contains($0.id.sectionKey) || listed.contains($0.id.sectionKey) }
        let launchers = corpus.compactMap { entry -> String? in
            if case .launcher(let bundle) = entry.action { return bundle }
            return nil
        }
        let model = PanelModel.build(
            roster: appState.settings.sectionModel.roster,
            items: items.map(\.id),
            drawnOrder: appState.lastDrawnOrder,
            didntFit: didntFit(appState),
            // Closed apps off: out of the panel at rest, a search still finds them.
            launchers: options.showsClosedApps || !query.isEmpty ? launchers : [],
            options: options,
            alwaysHiddenRequested: alwaysRequested,
            query: query,
            candidates: corpus.map(\.candidate),
            history: history)
        return (model, items)
    }

    /// What `refresh` and the preview draw: no state of the presenter's
    /// changes. A selection the filter or fold took away comes back nil.
    ///
    /// `aimed`: a tile in the air and the slot it is over. The sections are
    /// drawn as they would be with it dropped there, so the other tiles make
    /// room; the model returned is the one without it.
    private func buildContent(_ appState: AppState, layout: PanelGrid.Layout, query: String, selected: PanelTile?,
                              foldOpen: Bool, alwaysRequested: Bool, maxRowWidth: CGFloat? = nil,
                              aimed: (tile: PanelTile, slot: PanelSlot)? = nil)
        -> (content: PanelContent, missing: [ItemID], model: PanelModel)
    {
        let options = appState.settings.panel
        let (base, items) = buildModel(appState, query: query, alwaysRequested: alwaysRequested)
        // Each section is a grid of its own in the panel: the tile keeps its
        // dimmed place in the one it came from, so that one doesn't reflow
        // under the pointer. The row is one grid, where it only moves.
        let model = aimed.map { base.moving($0.tile, to: $0.slot, keepingOrigin: layout == .panel) } ?? base

        // What is on screen, in stacking order. A folded Always Hidden draws
        // its fold only; the row layout has no fold, so it leaves it out.
        struct Shown { let section: PanelSection; let folded: Bool }
        var shown: [Shown] = model.sections.compactMap { section in
            let folded = section.kind == .alwaysHidden && section.isFolded && !foldOpen
            if section.count == 0 { return nil }
            if layout == .row && folded { return nil }
            return Shown(section: section, folded: folded)
        }
        let alwaysShown = shown.contains { $0.section.kind == .alwaysHidden && !$0.folded }
        // The row merges them: the groups a drop is aimed at.
        var rowGroups: [PanelGroup] = []
        if layout == .row {
            // One row, as the bar draws it: Always Hidden left of Hidden, a
            // divider between groups.
            let order: [PanelSection.Kind] = [.didntFit, .alwaysHidden, .hidden]
            shown.sort { order.firstIndex(of: $0.section.kind)! < order.firstIndex(of: $1.section.kind)! }
            rowGroups = shown.map { PanelGroup(kind: $0.section.kind, tiles: $0.section.tiles.filter { $0 != .rowBreak }) }
            let tiles = shown.map(\.section.tiles).reduce(into: [PanelTile]()) { all, group in
                if !all.isEmpty { all.append(.rowBreak) }
                all += group
            }
            shown = tiles.isEmpty ? [] : [Shown(section: PanelSection(kind: .hidden, tiles: tiles, isFolded: false), folded: false)]
        }

        // The tile fold: a "+10" tile after Hidden's icons, in a Hidden of
        // its own when Hidden has none. A search shows matches, no fold.
        if layout == .panel, options.alwaysHiddenFold == .tile, query.isEmpty,
           let always = shown.firstIndex(where: { $0.section.kind == .alwaysHidden }) {
            if always > 0, shown[always - 1].section.kind == .hidden {
                var hidden = shown[always - 1].section
                hidden.tiles.append(.fold)
                shown[always - 1] = Shown(section: hidden, folded: false)
            } else {
                shown.insert(Shown(section: PanelSection(kind: .hidden, tiles: [.fold], isFolded: false), folded: false),
                             at: always)
            }
        }

        let columns = options.columns
        let minimum = shown.filter { !$0.folded }
            .map { PanelGrid.neededColumns(of: $0.section.tiles, maximum: columns) }.max() ?? 1
        let didntFitShown = shown.contains { $0.section.kind == .didntFit }
        var content = PanelContent(layout: layout, query: query)
        content.hasAlwaysHidden = model.sections.contains { $0.kind == .alwaysHidden && $0.count > 0 }
        content.showsAlwaysHidden = alwaysShown
        content.motion = Self.foldStyle(appState.settings.revealAnimation)
        content.fold = options.alwaysHiddenFold
        // Panel only (#95): the row is a strip along the bar, with no line
        // under the tiles for a cog to sit on.
        content.showsSettingsButton = options.showsSettingsButton && layout == .panel
        // The row's tiles are as wide as their pictures at bar size, so a
        // battery's "80%" isn't shrunk into a one-icon cell (#102). The
        // panel's tiles are one size, whatever they hold.
        var pictureWidths: [PanelTile: CGFloat] = [:]
        if layout == .row {
            for entry in shown {
                for case .item(let key) in entry.section.tiles {
                    if let picture = pictures.picture(for: key) { pictureWidths[.item(key)] = picture.size.width }
                }
            }
        }
        content.blocks = shown.map { entry in
            PanelBlock(
                kind: entry.section.kind,
                grid: PanelGrid(tiles: entry.section.tiles, columns: columns, layout: layout,
                                showsNames: options.showsNames, minimumColumns: minimum, maxWidth: maxRowWidth,
                                pictureWidths: pictureWidths),
                // The tile in the air is not one more behind the fold.
                count: layout == .panel ? base.section(entry.section.kind)?.count ?? entry.section.count : entry.section.count,
                showsHeader: layout == .panel && (entry.section.kind == .didntFit || (entry.section.kind == .hidden && didntFitShown)),
                foldable: layout == .panel && entry.section.kind == .alwaysHidden,
                isFolded: entry.folded,
                groups: rowGroups)
        }
        // A folded section sets no width. The search field wants room to
        // type into; otherwise the panel is as wide as its icons.
        content.width = max(content.blocks.filter { !$0.isFolded }.map(\.grid.contentSize.width).max() ?? 0,
                            query.isEmpty ? PanelMetrics.compact.wellSize.width : 150)

        let byKey = Dictionary(items.map { ($0.id.sectionKey, $0) }, uniquingKeysWith: { first, _ in first })
        // Didn't fit is on the bar, behind «: no pass reaches it. Read from
        // the model, as the row draws every section in one block.
        let didntFitKeys = Set(model.section(.didntFit)?.tiles.compactMap { tile -> ItemID? in
            if case .item(let key) = tile { return key }
            return nil
        } ?? [])
        var missing: [ItemID] = []
        for block in content.blocks where !block.isFolded {
            for tile in block.grid.rows.joined().map(\.tile) {
                switch tile {
                case .item(let key):
                    // The tiles whose menu offers "Move to…".
                    if !appState.isImmovable(key) { content.draggable.insert(tile) }
                    let item = byKey[key]
                    let name = item.map(ItemNaming.displayName(for:)) ?? ItemNaming.displayName(for: key)
                    if let picture = pictures.picture(for: key) {
                        content.art[tile] = PanelTileArt(
                            image: .picture(picture.image, size: picture.size, monochrome: picture.isMonochrome, highlighted: picture.isHighlighted), name: name)
                        // Shown while the pass retakes it.
                        if pictures.isStale(picture), !didntFitKeys.contains(key) { missing.append(key) }
                    } else {
                        content.art[tile] = PanelTileArt(image: .icon(Self.standIn(for: item?.id ?? key)), name: name)
                        if !didntFitKeys.contains(key) { missing.append(key) }
                    }
                case .launcher(let bundle):
                    content.art[tile] = PanelTileArt(
                        image: .icon(Self.launcherIcon(bundle)), name: ItemNaming.appName(forBundle: bundle) ?? bundle, dimmed: true)
                case .rowBreak, .fold:
                    break
                }
            }
        }
        content.selected = selected.flatMap { content.art[$0] == nil && $0 != .fold ? nil : $0 }
        return (content, missing, base)
    }

    /// The app's icon as launchers draw it, cached there: the preview
    /// rebuilds on every bar read and drag step.
    private static func launcherIcon(_ bundle: String) -> NSImage {
        ExtrasManager.appIcon(for: ExtraItemSpec(kind: .appLauncher, bundleID: bundle), size: 20) ?? placeholder
    }

    /// The editor's stand-in (`ItemStandIn`): Apple's own mark for
    /// SystemUIServer's pair, whose icon is a blank square (#19).
    private static func standIn(for id: ItemID) -> NSImage {
        ItemStandIn.image(for: id) ?? placeholder
    }

    private static let placeholder: NSImage = {
        let image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    // MARK: - Actions

    func press(_ tile: PanelTile) {
        guard let appState else { return }
        switch tile {
        case .item(let key):
            PelmetLog.log("panel: press \(key.rawValue)")
            let display = openScreen
            appState.concealNow()
            // Waits out a pass under way (openItemMenu). Clicked on the
            // panel's display's bar, so the menu opens there (#26).
            appState.openItemMenu(key, display: display)
        case .launcher(let bundle):
            PelmetLog.log("panel: launch \(bundle)")
            appState.concealNow()
            guard let url = ExtrasManager.appURL(for: ExtraItemSpec(kind: .appLauncher, bundleID: bundle)) else {
                PelmetLog.log("panel: no app for \(bundle)")
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { PelmetLog.log("panel: opening \(bundle) failed — \(error.localizedDescription)") }
            }
        case .fold:
            toggleFold()
        case .rowBreak:
            break
        }
    }

    // MARK: - Tile drag

    /// A tile in the air, from the first 4pt of travel until it lands or goes
    /// back (docs/PANEL-PLAN.md D1: between sections, and in them since
    /// 2026-10-12).
    private final class TileDrag {
        let tile: PanelTile
        let key: ItemID
        /// Where it came from, by the model.
        let origin: PelmetCore.Section
        let ghost: PanelDragGhost
        /// The pointer less the ghost's centre, kept from where it was grabbed.
        let grab: CGSize
        /// The tile's well centre from the window's top right (y down): where
        /// it goes back to. The panel is anchored there, so a widen does not
        /// move it.
        let home: CGPoint
        /// The place in a section it is over: the tiles there make room.
        var slot: PanelSlot?
        /// The slot the panel on screen was drawn with, which the tiles'
        /// frames are read against.
        var shownSlot: PanelSlot?
        /// The tiles are still easing before this: the frames are not final.
        var settledAt: CFTimeInterval = 0
        /// The gap on the bar it is over, which a line marks.
        var barGap: PanelBarGap?
        var line: PanelInsertionLine?
        /// The bar's Visible icons, read from the walk once per drag.
        var barIcons: (icons: [PanelBarGap.Icon], edge: CGFloat?)?
        var barIconsRead = false
        /// What the last tick that ran to its end read: the same again is a
        /// pointer at rest over the same panel, nothing to do.
        var lastTick: DragTick?
        let started = CACurrentMediaTime()

        init(tile: PanelTile, key: ItemID, origin: PelmetCore.Section, ghost: PanelDragGhost, grab: CGSize, home: CGPoint) {
            self.tile = tile
            self.key = key
            self.origin = origin
            self.ghost = ghost
            self.grab = grab
            self.home = home
        }
    }

    /// What a drag tick reads: the pointer, the glass (a fold grows it, the
    /// entrance moves it) and the panel's layout as drawn.
    private struct DragTick: Equatable {
        let pointer: CGPoint
        let glass: CGRect?
        let frames: Int
        let draws: Int
    }

    /// The fold springs open after this long over it (the mock's 600ms).
    private static let springDelay: Duration = .milliseconds(600)
    /// After a redraw for the tile in the air, the pointer is not read against
    /// the new frames for this long: SwiftUI reports them a beat later.
    private static let makeRoomSettle: CFTimeInterval = 0.04
    /// After the release that ends a drag, the button under the pointer
    /// fires on it too: no press for this long.
    private static let pressGuard: CFTimeInterval = 0.35

    /// From a tile's gesture: the start, the end, and the ghost kept under
    /// every move it reports (a 60Hz tick trails a 120Hz pointer). What the
    /// ghost is over is read on screen, on a timer, which also keeps it up
    /// with a pointer SwiftUI no longer reports.
    private func tileDragged(_ tile: PanelTile, _ phase: PanelTileDrag) {
        switch phase {
        case .moved(let pointer, let wellCenter):
            if let drag = tileDrag {
                let mouse = NSEvent.mouseLocation
                drag.ghost.move(toCenter: CGPoint(x: mouse.x - drag.grab.width, y: mouse.y - drag.grab.height))
                return
            }
            guard !ignoresDragUntilRelease, NSEvent.pressedMouseButtons & 1 != 0 else { return }
            beginDrag(tile, pointer: pointer, wellCenter: wellCenter)
            tickDrag()
        case .ended:
            released()
        }
    }

    /// The button came up (the gesture's end, a mouse-up seen directly, or a
    /// button found up by the timer; whichever is first): the drop, and the
    /// click that ends a drag is not one.
    private func released() {
        pressEnded()
        if tileDrag != nil { finishDrag(cancel: false) }
    }

    /// The press is over: the next one is a click or a drag again, once the
    /// guard has passed.
    private func pressEnded() {
        ignoresDragUntilRelease = false
        pressGuardUntil = CACurrentMediaTime() + Self.pressGuard
        stopWatchingMouse()
    }

    private func watchMouse() {
        guard mouseMonitors.isEmpty else { return }
        let seen: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                // A new press: whatever was cancelled before it is over.
                if event.type == .leftMouseUp { self?.released() } else { self?.ignoresDragUntilRelease = false }
            }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: seen) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            seen(event)
            return event
        }) { mouseMonitors.append(local) }
    }

    private func stopWatchingMouse() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
    }

    private func beginDrag(_ tile: PanelTile, pointer: CGPoint, wellCenter: CGPoint) {
        guard isOpen, let appState, let window, let content = lastContent, case .item(let key) = tile,
              content.draggable.contains(tile), let art = content.art[tile],
              let block = content.blocks.first(where: { $0.grid.frame(of: tile) != nil })
        else { return }
        // An Apply or grouping pass has the bar, and `moveItem` ignores a drop
        // that lands during one: no drag to begin, and its release is no click.
        guard !appState.applying else {
            PelmetLog.log("panel: drag of \(key.rawValue) refused, a pass has the bar")
            ignoresDragUntilRelease = true
            watchMouse()
            return
        }
        let origin = appState.settings.sectionModel.section(of: key)
        // The tile's well, on screen: where the pointer is, less how far into
        // the tile it was (the tile's y runs down, the screen's up).
        let mouse = NSEvent.mouseLocation
        let center = CGPoint(x: mouse.x - (pointer.x - wellCenter.x), y: mouse.y + (pointer.y - wellCenter.y))
        let ghost = PanelDragGhost(art: art, grid: block.grid, tileWidth: block.grid.tileWidth(of: tile), appearance: window.appearance)
        let drag = TileDrag(
            tile: tile, key: key, origin: origin, ghost: ghost,
            grab: CGSize(width: mouse.x - center.x, height: mouse.y - center.y),
            home: CGPoint(x: window.frame.maxX - center.x, y: window.frame.maxY - center.y))
        tileDrag = drag
        watchMouse()
        ghost.show(at: center)
        withAnimation(.easeOut(duration: 0.15)) { dragState.tile = tile }
        PelmetLog.log("panel: drag \(key.rawValue) from \(origin.rawValue)")
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickDrag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
        let escape: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 0x35 else { return }
            MainActor.assumeIsolated { self?.cancelDrag() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: escape) { escMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            escape(event)
            return event.keyCode == 0x35 ? nil : event
        }) { escMonitors.append(local) }
    }

    /// The ghost under the pointer, and the target it is over.
    private func tickDrag() {
        guard let drag = tileDrag else { return }
        // Polled too, for a key held down when the monitors' events came late.
        if CGEventSource.keyState(.combinedSessionState, key: 0x35) {
            cancelDrag()
            return
        }
        // A release nothing reported: the drag ends where the button came up.
        if NSEvent.pressedMouseButtons & 1 == 0, CACurrentMediaTime() - drag.started > 0.15 {
            released()
            return
        }
        let pointer = NSEvent.mouseLocation
        let tick = DragTick(pointer: pointer, glass: window?.glassScreenFrame, frames: framesSeen, draws: draws)
        guard tick != drag.lastTick else { return }
        drag.ghost.move(toCenter: CGPoint(x: pointer.x - drag.grab.width, y: pointer.y - drag.grab.height))
        let over = dropZones()?.hit(at: pointer) ?? .none
        // The tile's own section lights nothing: that is no move.
        let hit = over.section == drag.origin ? PanelDropZones.Hit.none : over
        if hit != dragState.target { targetChanged(to: hit) }
        drag.lastTick = aim(drag, over: over, at: pointer) ? tick : nil
    }

    // MARK: - Aim

    /// Where in what it is over the tile would land. Over Hidden or Always
    /// Hidden, its own section included, a slot among the tiles, shown by the
    /// others making room; over the bar, a gap between two icons, shown by a
    /// line. Elsewhere nothing, and the panel is as it was. False while the
    /// frames are not the last draw's yet: the slot waits for them.
    @discardableResult
    private func aim(_ drag: TileDrag, over: PanelDropZones.Hit, at pointer: CGPoint) -> Bool {
        let gap = over == .section(.visible) && drag.origin != .visible ? barGap(at: pointer, for: drag) : nil
        if gap != drag.barGap {
            drag.barGap = gap
            if let gap, let screen = window?.screen ?? NSScreen.main {
                let line = drag.line ?? PanelInsertionLine(appearance: window?.appearance)
                drag.line = line
                line.show(at: gap.x, over: Self.barBand(of: screen))
                PelmetLog.log("panel: drag bar gap x=\(Int(gap.x)) before=\(gap.before?.rawValue ?? "end")")
            } else {
                drag.line?.hide()
                PelmetLog.log("panel: drag bar gap none")
            }
        }
        // The frames belong to the last draw: wait out a redraw under way and
        // the tiles' easing.
        guard reshuffleTask == nil, CACurrentMediaTime() >= drag.settledAt else { return false }
        let proposed = slotUnder(pointer, over: over, for: drag)
        // Its own place again is the panel as it was: no slot to draw.
        let slot = proposed.flatMap { lastModel?.changes(drag.tile, at: $0) == true ? $0 : nil }
        if slot != drag.slot {
            drag.slot = slot
            if let slot, let base = lastModel,
               let tiles = base.moving(drag.tile, to: slot, keepingOrigin: true).section(slot.kind)?.tiles {
                let next = PanelReorder.neighbour(of: drag.tile, in: tiles)
                PelmetLog.log("panel: drag slot \(slot.kind.rawValue) \(slot.index)/\(tiles.count) "
                    + "before=\(next.item?.rawValue ?? "end")\(next.afterBreak ? " (after a break)" : "")")
            } else {
                PelmetLog.log(proposed == nil ? "panel: drag slot none" : "panel: drag slot home")
            }
            reshuffle()
            return false
        }
        return true
    }

    /// The slot in Hidden or Always Hidden under `pointer`, read against the
    /// tiles as the last draw put them.
    private func slotUnder(_ pointer: CGPoint, over: PanelDropZones.Hit, for drag: TileDrag) -> PanelSlot? {
        let kind: PanelSection.Kind
        switch over {
        case .section(.hidden): kind = .hidden
        case .section(.alwaysHidden): kind = .alwaysHidden
        // The fold is a drop of its own; no slot in what it hides.
        default: return nil
        }
        // A search ranks the tiles by match, not by the bar: a place among
        // them means nothing there. The drop files it in the section.
        guard query.isEmpty, let base = lastModel, let content = lastContent else { return nil }
        let panel = content.layout == .panel
        let shown = drag.shownSlot.map { base.moving(drag.tile, to: $0, keepingOrigin: panel) } ?? base
        // The row is one grid, laid out from its first block.
        let block = panel ? content.blocks.first { $0.kind == kind && !$0.isFolded } : content.blocks.first
        guard let tiles = shown.section(kind)?.tiles, let block, let grid = screenFrame(of: .grid(block.kind)) else { return nil }
        var frames: [PanelTile: CGRect] = [:]
        for placement in block.grid.rows.joined() where tiles.contains(placement.tile) {
            let cell = placement.frame
            frames[placement.tile] = CGRect(x: grid.minX + cell.minX, y: grid.maxY - cell.maxY, width: cell.width, height: cell.height)
        }
        return PanelReorder.index(at: pointer, tiles: tiles, frames: frames, dragged: drag.tile)
            .map { PanelSlot(kind: kind, index: $0) }
    }

    /// Draws the panel again for the slot the drag now aims at. Queued, not
    /// run from the gesture's own callback.
    private func reshuffle() {
        guard reshuffleTask == nil else { return }
        reshuffleTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.reshuffleTask = nil
            if self.isOpen { self.refresh() }
        }
    }

    /// The gap between Visible icons nearest `pointer`, from the walk: the
    /// icons on the panel's display, the chevron's edge counting as one.
    private func barGap(at pointer: CGPoint, for drag: TileDrag) -> PanelBarGap? {
        if !drag.barIconsRead {
            drag.barIconsRead = true
            drag.barIcons = barIcons(for: drag)
        }
        guard let bar = drag.barIcons else { return nil }
        return PanelBarGap.nearest(to: pointer.x, icons: bar.icons, edge: bar.edge)
    }

    /// The Visible icons a drag can aim between, read once per drag.
    private func barIcons(for drag: TileDrag) -> (icons: [PanelBarGap.Icon], edge: CGFloat?)? {
        // The walk keeps the main display's copy of each icon: a side bar
        // has too few to aim between, and the drop takes the default place.
        guard let appState, let snapshot = appState.snapshot, let screen = window?.screen ?? NSScreen.main,
              let id = screen.directDisplayID, id == CGMainDisplayID() else { return nil }
        // AX frames: top-left origin, in the display's own bounds.
        let display = CGDisplayBounds(id)
        let behindOverflow = Set(appState.overflowTrappedItems.map(\.sectionKey))
        let model = appState.settings.sectionModel
        var edge: CGFloat?
        var icons: [PanelBarGap.Icon] = []
        var seen: Set<ItemID> = [drag.key.sectionKey]
        for item in snapshot.items {
            guard let frame = item.frame, MenuBarGeometry.isInBand(frame, ofDisplay: display) else { continue }
            if MenuBarPolicy.isChevronID(item.id, pelmetBundleID: PelmetBundle.mainID) {
                edge = frame.maxX
                continue
            }
            let key = item.id.sectionKey
            guard model.section(of: key) == .visible, !behindOverflow.contains(key), seen.insert(key).inserted else { continue }
            icons.append(PanelBarGap.Icon(id: key, minX: frame.minX, maxX: frame.maxX, movable: !appState.isImmovable(item.id)))
        }
        // Visible icons sit right of the chevron; one left of it is mid-move.
        if let edge { icons.removeAll { ($0.minX + $0.maxX) / 2 < edge } }
        return (icons, edge)
    }

    private func targetChanged(to hit: PanelDropZones.Hit) {
        withAnimation(.easeOut(duration: 0.12)) { dragState.target = hit }
        switch hit {
        case .none: PelmetLog.log("panel: drag over nothing")
        case .fold: PelmetLog.log("panel: drag over the fold")
        case .section(let section): PelmetLog.log("panel: drag over \(section.rawValue)")
        }
        springTask?.cancel()
        springTask = nil
        // Held over the closed fold it opens, for this open only: nothing is
        // stored.
        guard hit == .fold, let content = lastContent, content.layout == .panel,
              content.blocks.contains(where: { $0.kind == .alwaysHidden && $0.isFolded })
        else { return }
        springTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.springDelay)
            guard let self, !Task.isCancelled, self.dragState.target == .fold else { return }
            self.springTask = nil
            self.openFoldForDrag()
        }
    }

    private func openFoldForDrag() {
        guard isOpen, let appState else { return }
        PelmetLog.log("panel: drag opened Always Hidden")
        foldOpen = true
        foldMotion = Self.foldStyle(appState.settings.revealAnimation)
        let shown = refresh()
        picturePassUnlessBarDrag(shown.missing)
    }

    private func cancelDrag() {
        // The key's own event is still on its way to the panel's handler.
        escSwallowUntil = CACurrentMediaTime() + 0.5
        finishDrag(cancel: true)
    }

    /// Where a drop goes: the section, and the icon it goes in front of (nil is
    /// the end). `aimed`: at a place the drag showed; otherwise the plain move
    /// for the section.
    private struct Landing {
        let section: PelmetCore.Section
        let before: ItemID?
        let aimed: Bool
    }

    /// The drop at `point`: what the drag showed under the pointer, else the
    /// section it is over. Nothing for the tile's own section left as it was,
    /// and for anywhere else: it goes back to where it was.
    private func dropLanding(of drag: TileDrag, at point: CGPoint) -> Landing? {
        guard let appState else { return nil }
        switch dropZones()?.hit(at: point) ?? .none {
        case .none:
            return nil
        case .fold:
            return drag.origin == .alwaysHidden ? nil : Landing(section: .alwaysHidden, before: nil, aimed: false)
        case .section(.visible):
            guard drag.origin != .visible else { return nil }
            return Landing(section: .visible, before: drag.barGap?.before, aimed: drag.barGap != nil)
        case .section(let section):
            let kind: PanelSection.Kind = section == .alwaysHidden ? .alwaysHidden : .hidden
            if let slot = drag.slot, slot.kind == kind, let base = lastModel,
               let tiles = base.moving(drag.tile, to: slot, keepingOrigin: true).section(kind)?.tiles {
                let next = PanelReorder.neighbour(of: drag.tile, in: tiles)
                return Landing(section: section, before: appState.dropAnchor(before: next, in: section, moving: drag.key), aimed: true)
            }
            return section == drag.origin ? nil : Landing(section: section, before: nil, aimed: false)
        }
    }

    /// The drop: a place in a section takes it; anywhere else, or where it
    /// came from, it goes back to where it was. `closing`: the panel is going,
    /// the ghost only fades.
    private func finishDrag(cancel: Bool, closing: Bool = false) {
        guard let drag = tileDrag else { return }
        var landing = cancel ? nil : dropLanding(of: drag, at: NSEvent.mouseLocation)
        // `moveItem` ignores a drop during a pass: it goes back, it doesn't land.
        if landing != nil, appState?.applying == true {
            PelmetLog.log("panel: drop of \(drag.key.rawValue) refused, a pass has the bar")
            landing = nil
        }
        tileDrag = nil
        dragTimer?.invalidate()
        dragTimer = nil
        for monitor in escMonitors { NSEvent.removeMonitor(monitor) }
        escMonitors = []
        springTask?.cancel()
        springTask = nil
        reshuffleTask?.cancel()
        reshuffleTask = nil
        drag.line?.close()
        // The tiles that made room go back, or settle, with the same ease.
        easeUntil = CACurrentMediaTime() + 0.4
        withAnimation(.easeOut(duration: 0.15)) {
            dragState.tile = nil
            dragState.target = .none
        }
        // Cancelled with the button still down: the rest of that press is not a
        // click. The release ends it (`released`).
        if NSEvent.pressedMouseButtons & 1 != 0 {
            ignoresDragUntilRelease = true
        } else {
            pressEnded()
        }
        // Let go past the edge, it holds until the pointer comes back (the
        // column grip does the same).
        awaitsPointer = true
        if let landing, let appState {
            PelmetLog.log("panel: drop \(drag.key.rawValue) → \(landing.section.rawValue)"
                + (landing.aimed ? " before=\(landing.before?.rawValue ?? "end")" : ""))
            drag.ghost.release()
            // Quiet: the panel stays open on the new order while the pass
            // runs, and the bar stays under its cover (applyOrderEdits).
            if landing.aimed {
                appState.moveItemNow(drag.key, to: landing.section, before: landing.before, quiet: true)
            } else {
                appState.moveItemNow(drag.key, to: landing.section, quiet: true)
            }
            if isOpen { refresh() }
        } else {
            PelmetLog.log("panel: drag cancelled")
            // What the tiles made room for is gone with the drag; the home is
            // read from the panel as it is drawn again.
            if !closing, isOpen, drag.shownSlot != nil { refresh() }
            let home = closing ? nil : window.map { CGPoint(x: $0.frame.maxX - drag.home.x, y: $0.frame.maxY - drag.home.y) }
            drag.ghost.slideBack(toCenter: home, reduceMotion: Self.reduceMotion)
        }
    }

    /// What the pointer can drop on, in screen points: the glass, the bar's
    /// band, and the parts SwiftUI laid out.
    private func dropZones() -> PanelDropZones? {
        guard let window, let content = lastContent, let screen = window.screen ?? NSScreen.main else { return nil }
        var zones = PanelDropZones(bar: Self.barBand(of: screen), panel: window.glassScreenFrame)
        func onScreen(_ key: PanelFrameKey) -> CGRect? { screenFrame(of: key) }
        if content.layout == .row {
            // One grid; its tiles are placed from its corner (y runs down).
            if let block = content.blocks.first, let grid = onScreen(.grid(block.kind)) {
                zones.groups = block.groups.map { group in
                    PanelDropZones.Group(kind: group.kind, tiles: group.tiles.compactMap { block.grid.frame(of: $0) }.map {
                        CGRect(x: grid.minX + $0.minX, y: grid.maxY - $0.maxY, width: $0.width, height: $0.height)
                    })
                }
            }
            return zones
        }
        if content.blocks.contains(where: { $0.kind == .didntFit }) { zones.didntFit = onScreen(.section(.didntFit)) }
        // The fold is a tile of Hidden's grid, placed from the grid's corner
        // (an offset is not a layout frame: SwiftUI reports where the tile was
        // laid out, not where it is drawn), or its own count or handle.
        if let block = content.blocks.first(where: { $0.grid.frame(of: .fold) != nil }),
           let cell = block.grid.frame(of: .fold), let grid = onScreen(.grid(block.kind)) {
            zones.fold = CGRect(x: grid.minX + cell.minX, y: grid.maxY - cell.maxY, width: cell.width, height: cell.height)
        } else if content.query.isEmpty, content.fold != .tile, content.blocks.contains(where: { $0.foldable }) {
            zones.fold = onScreen(.fold)
        }
        if content.blocks.contains(where: { $0.kind == .alwaysHidden && !$0.isFolded }) {
            zones.alwaysHidden = onScreen(.grid(.alwaysHidden))
        }
        return zones
    }

    /// Where SwiftUI laid out `key`, in screen points.
    private func screenFrame(of key: PanelFrameKey) -> CGRect? {
        guard let window, let hosting else { return nil }
        return frames[key].map { window.convertToScreen(hosting.convert($0, to: nil)) }
    }

    // MARK: - Bar drag

    /// Where a ⌘-drag from the bar can end on the open panel, in screen
    /// points (`BarDragRedirect`): the drop zone, stopped at the bar's band
    /// so a drop on the bar stays the bar's.
    func barDragZone() -> CGRect? {
        guard isOpen, let zones = dropZones() else { return nil }
        return Self.barDragZone(of: zones)
    }

    private static func barDragZone(of zones: PanelDropZones) -> CGRect {
        var zone = zones.zone
        zone.size.height = max(0, min(zone.maxY, zones.bar.minY) - zone.minY)
        return zone
    }

    /// A ⌘-drag from the bar is under way (it opened the panel, or the panel
    /// can take its drop): set until it ends, the panel closes, or the
    /// button is found up.
    private var barDragging = false

    private var barDragInFlight: Bool {
        barDragging && NSEvent.pressedMouseButtons & 1 != 0
    }

    /// The picture pass reveals the real bar under a cover: never under a
    /// ⌘-drag MenuBarAgent is running there (a ⌘-drag's open, a fold it
    /// springs). The next open takes the pictures.
    private func picturePassUnlessBarDrag(_ missing: [ItemID]) {
        guard !barDragInFlight else {
            if !missing.isEmpty { PelmetLog.log("panel: picture pass deferred — a bar ⌘-drag is in flight, \(missing.count) without a fresh picture") }
            return
        }
        picturePassIfNeeded(missing)
    }

    /// A ⌘-drag from the bar can now end on the panel: a copy of the icon
    /// rides under the pointer while it is over it, where the tap keeps the
    /// real one in its slot (`BarDragRedirect`).
    func beginBarDrag(_ id: ItemID?) {
        barDragging = true
        barGhost?.release()
        barGhost = nil
        guard isOpen, let window, let grid = lastContent?.blocks.first?.grid else { return }
        let art: PanelTileArt
        var pictureWidth: CGFloat?
        if let id, let picture = pictures.picture(for: id.sectionKey) {
            art = PanelTileArt(image: .picture(picture.image, size: picture.size, monochrome: picture.isMonochrome, highlighted: picture.isHighlighted), name: "")
            pictureWidth = picture.size.width
        } else {
            art = PanelTileArt(image: .icon(id.map(Self.standIn(for:)) ?? Self.placeholder), name: "")
        }
        // The tile it would land as: the row's follow their pictures (#102).
        barGhost = PanelDragGhost(art: art, grid: grid, tileWidth: grid.metrics.rowTileWidth(forPicture: pictureWidth),
                                  appearance: window.appearance)
    }

    /// A ⌘-drag from the bar is at `point`: lights the section a drop there
    /// files the icon in, and returns it with the zone the drag can end on,
    /// both from one read of the drop zones (a drag event comes every few ms).
    @discardableResult
    func barDrag(at point: CGPoint) -> (section: PelmetCore.Section?, zone: CGRect?) {
        let zones = isOpen ? dropZones() : nil
        let zone = zones.map(Self.barDragZone(of:))
        var hit = zones?.hit(at: point) ?? .none
        if hit == .section(.visible) { hit = .none }
        if let barGhost {
            if zone?.contains(point) == true { barGhost.show(at: point) } else { barGhost.hide() }
        }
        // Held over the fold it springs open, as for a tile.
        if hit != dragState.target { targetChanged(to: hit) }
        return (hit.section, zone)
    }

    /// The ⌘-drag is over, whether the panel could take its drop or not.
    func endBarDrag() {
        barDragging = false
        barGhost?.release()
        barGhost = nil
        springTask?.cancel()
        springTask = nil
        guard dragState.target != .none else { return }
        withAnimation(.easeOut(duration: 0.12)) { dragState.target = .none }
    }

    // MARK: - Columns

    /// Columns from the pointer, `distance` left of the panel's right edge:
    /// that edge stays put, so each tile's width left of it is one more
    /// column. Two at least, no more than the widest section of `model` can
    /// fill, ten at most. Stored for the current names mode, and saved once
    /// the drag is let go (`ended`); returned for the tip.
    @discardableResult
    func setColumns(distance: CGFloat, model: PanelModel?, ended: Bool) -> Int {
        guard let appState else { return 0 }
        let options = appState.settings.panel
        let metrics = PanelMetrics.standard(layout: .panel, showsNames: options.showsNames)
        let pitch = metrics.tileSize.width + metrics.columnGap
        let want = Int(((distance - metrics.padding + metrics.columnGap) / pitch).rounded())
        let range = PanelOptions.columnRange
        let most = max(range.lowerBound,
                       model?.sections.map { PanelGrid.neededColumns(of: $0.tiles, maximum: range.upperBound) }.max() ?? range.lowerBound)
        let columns = min(max(want, range.lowerBound), most)
        if options.columns != columns {
            appState.settings.panel.columns = columns
            columnsUnsaved = true
            PelmetLog.log("panel: \(columns) column(s)")
        }
        if ended, columnsUnsaved {
            columnsUnsaved = false
            appState.settingsChanged()
        }
        return columns
    }

    func setAutoColumns() {
        guard let appState else { return }
        appState.settings.panel.columns = nil
        appState.settingsChanged()
        PelmetLog.log("panel: columns Auto")
    }

    private func dragColumns(ended: Bool) {
        guard let window else { return }
        // The mouse-up seen directly ended it first: the gesture's own end,
        // when SwiftUI reports one, has nothing left to do.
        if ended, !draggingColumns { return }
        if !ended, !draggingColumns { watchColumnRelease() }
        draggingColumns = !ended
        if ended {
            awaitsPointer = true
            stopWatchingColumnRelease()
        }
        // The window moves as it widens: the pointer is read on screen.
        let columns = setColumns(distance: window.frame.maxX - NSEvent.mouseLocation.x, model: lastModel, ended: ended)
        showTip(String(localized: "\(columns) per row"), for: ended ? 0.5 : nil)
    }

    /// A column drag cut short by the panel closing: saved where it got to.
    private func endColumnDrag() {
        draggingColumns = false
        stopWatchingColumnRelease()
        saveColumnsIfUnsaved()
    }

    /// A column drag whose end never came (SwiftUI drops a gesture on a key
    /// press; the Settings preview going with one under way): saved where it
    /// got to.
    func saveColumnsIfUnsaved() {
        guard columnsUnsaved, let appState else { return }
        columnsUnsaved = false
        appState.settingsChanged()
        PelmetLog.log("panel: columns saved, the drag's end never came")
    }

    private func watchColumnRelease() {
        guard columnMonitors.isEmpty else { return }
        let seen: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.draggingColumns else { return }
                PelmetLog.log("panel: column drag let go")
                self.dragColumns(ended: true)
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: seen) { columnMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { event in
            seen(event)
            return event
        }) { columnMonitors.append(local) }
    }

    private func stopWatchingColumnRelease() {
        for monitor in columnMonitors { NSEvent.removeMonitor(monitor) }
        columnMonitors = []
    }

    private func resetColumns() {
        awaitsPointer = true
        setAutoColumns()
        showTip(String(localized: "Auto"), for: 0.8)
    }

    /// Up until `seconds` pass, or until the next call when nil. The text
    /// follows the column count, so a new one is a new layout; the same one
    /// (every move of a drag within a column) leaves the panel alone.
    private func showTip(_ text: String, for seconds: Double?) {
        tipTask?.cancel()
        if columnsTip != text {
            columnsTip = text
            refresh()
        }
        guard let seconds else { return }
        tipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.columnsTip = nil
            if self.isOpen { self.refresh() }
        }
    }

    // MARK: - Right-click

    /// The mock's tile menu: the presses, the moves between sections, the
    /// app. The command bar's ⌘K list has the same rows.
    func menu(for tile: PanelTile) -> [PanelMenuRow] {
        guard let appState else { return [] }
        switch tile {
        case .item(let key):
            var rows: [PanelMenuRow] = [
                .action(ItemMenuActions.openMenuTitle) { [weak self] in self?.press(tile) },
                .action(String(localized: "Open Right-Click Menu")) { [weak self, weak appState] in
                    PelmetLog.log("panel: right-click \(key.rawValue)")
                    let display = self?.openScreen
                    appState?.concealNow()
                    appState?.openItemMenu(key, button: .secondary, display: display)
                },
                .action(ItemMenuActions.showInBarTitle) { [weak appState] in
                    guard let appState else { return }
                    ItemMenuActions.showInBar(key, appState: appState, source: "panel")
                },
            ]
            let targets = ItemMenuActions.moveTargets(of: key, appState: appState)
            if !targets.isEmpty {
                rows.append(.divider)
                for section in targets {
                    rows.append(.action(ItemMenuActions.moveTitle(section)) { [weak appState] in
                        PelmetLog.log("panel: move \(key.rawValue) to \(section.rawValue)")
                        appState?.concealNow()
                        appState?.moveItemNow(key, to: section)
                    })
                }
            }
            rows.append(.divider)
            rows.append(.action(ItemMenuActions.shortcutTitle(key, appState: appState)) { [weak appState] in
                guard let appState else { return }
                appState.concealNow()
                ItemMenuActions.editShortcut(key, appState: appState, source: "panel")
            })
            if let app = corpusApps[key], ItemMenuActions.isRunning(app.bundleID) {
                rows.append(.divider)
                rows.append(.action(ItemMenuActions.quitTitle(app.name)) { [weak appState] in
                    appState?.concealNow()
                    ItemMenuActions.quit(app.bundleID, source: "panel")
                })
            }
            return rows
        case .launcher(let bundle):
            let name = ItemNaming.appName(forBundle: bundle) ?? bundle
            return [.action(String(localized: "Open \(name)")) { [weak self] in self?.press(tile) }]
        case .rowBreak, .fold:
            return []
        }
    }

    /// The mock's panel menu: the layout, names, Always Hidden, Settings.
    /// `shown` is what the panel it opens on draws, `toggleFold` its fold.
    /// `onPanel`: the open panel's, whose Layout is its display's; else
    /// Settings' preview, whose Layout is the Panel tab's.
    func panelMenu(shown: PanelContent?, onPanel: Bool = false, toggleFold: @escaping () -> Void) -> [PanelMenuRow] {
        guard let appState else { return [] }
        let layout = onPanel ? self.layout : appState.revealTarget.panelLayout ?? .panel
        let display = onPanel ? openScreen : nil
        let alwaysShown = shown?.showsAlwaysHidden ?? false
        let hasAlways = shown?.hasAlwaysHidden ?? false
        return [
            .header(String(localized: "Layout")),
            .check(String(localized: "Panel"), layout == .panel) { [weak self] in self?.pick(.panel, onDisplay: display) },
            .check(String(localized: "Row"), layout == .row) { [weak self] in self?.pick(.row, onDisplay: display) },
            .divider,
            .check(String(localized: "Show Names"), appState.settings.panel.showsNames, enabled: layout == .panel) { [weak self] in
                guard let self, let appState = self.appState else { return }
                appState.settings.panel.showsNames.toggle()
                appState.settingsChanged()
                if self.isOpen { self.refresh() }
            },
            .check(String(localized: "Show Closed Apps"), appState.settings.panel.showsClosedApps) { [weak self] in
                guard let self, let appState = self.appState else { return }
                appState.settings.panel.showsClosedApps.toggle()
                appState.settingsChanged()
                if self.isOpen { self.refresh() }
            },
            .check(String(localized: "Always Hidden"), alwaysShown, enabled: hasAlways, toggleFold),
            .divider,
            .action(String(localized: "Dimble Settings…")) { [weak appState] in
                appState?.concealNow()
                appState?.openSettings(tab: .panel)
            },
        ]
    }

    /// The layout picked from the panel's menu, or the bar's, is the setting
    /// from then on: the display's own when it was picked on one that has
    /// its own (Settings › Displays), the Panel tab's otherwise.
    func pick(_ target: RevealTarget, onDisplay display: CGDirectDisplayID?) {
        let uuid = display.flatMap(NSScreen.uuid(ofDisplay:))
        let own = appState?.settings.ownRevealTarget(forDisplayUUID: uuid) != nil
        setTarget(target, forDisplayUUID: own ? uuid : nil)
    }

    /// The Panel tab's "Show hidden icons in", or with `uuid` that display's
    /// own (nil: "Same as Panel tab"). Panel ↔ Row re-lays an open panel. A
    /// pick that moves the icons out now between the bar and a panel hides
    /// them instead: whatever showed them takes them down, and the next open
    /// uses the new place (#26). Refreshing would draw Menu bar as a grid,
    /// and a bar reveal would stay out with nothing to close it. A reveal
    /// that needed the bar whatever the choice (Apply, the editor's preview)
    /// stays.
    func setTarget(_ target: RevealTarget?, forDisplayUUID uuid: String? = nil) {
        guard let appState else { return }
        if let uuid {
            appState.settings.displayRevealTargets[uuid] = target
        } else if let target {
            appState.settings.hiddenIconsIn = target
        }
        appState.settingsChanged()
        PelmetLog.log("panel: layout \(target?.rawValue ?? "same as the Panel tab")\(uuid.map { " for display \($0)" } ?? "")")
        // The reveal out now, on the display it was decided on.
        guard let shown = appState.revealDecision, shown.followsChoice else {
            if isOpen { refresh() }
            return
        }
        let after = appState.settings.revealTarget(forDisplayUUID: shown.uuid)
        let crossesBar = (shown.target.panelLayout == nil) != (after.panelLayout == nil)
        if !crossesBar, isOpen { appState.revealRetargeted(after) }
        if crossesBar {
            PelmetLog.log("panel: layout moved the open icons, concealing")
            appState.concealNow()
        } else if isOpen {
            refresh()
        }
    }

    /// Always Hidden's fold flipped on a panel that shows it (`shown`) or
    /// not; returns that panel's own fold: open when it was not shown. As
    /// you left it: the setting carries the fold to the next open, saved
    /// only when it changes, and the panel's own stays shut.
    func flipFold(shown: Bool) -> Bool {
        guard let appState, appState.settings.panel.alwaysHidden == .asLeft else { return !shown }
        if appState.settings.panel.alwaysHiddenOpen == shown {
            appState.settings.panel.alwaysHiddenOpen = !shown
            appState.settingsChanged()
        }
        return false
    }

    private func toggleFold() {
        // A right-click menu can outlive the panel it was opened on.
        guard isOpen else {
            PelmetLog.log("panel: fold ignored — the panel is closed")
            return
        }
        let shown = lastContent?.showsAlwaysHidden ?? false
        // Opened for Always Hidden (⌥-click, a double-click, its shortcut):
        // the ask held the fold open whatever the fold said, so folding it
        // lets go of the ask, the machine's too: a ⌥-click then asks again.
        if shown, sections.contains(.alwaysHidden) {
            sections.remove(.alwaysHidden)
            PelmetLog.log("panel: Always Hidden folded, the open's ask for it let go")
            appState?.sectionsPutAway([.alwaysHidden])
        }
        foldOpen = flipFold(shown: shown)
        if let appState { foldMotion = Self.foldStyle(appState.settings.revealAnimation) }
        let drawn = refresh()
        picturePassIfNeeded(drawn.missing)
    }

    // MARK: - Dev

    /// The open panel as it is on screen, glass, desktop and all, written to
    /// ~/Library/Logs/Dimble/pass/panel.png: for checking it with no one at
    /// the Mac (`app.fif7y.Pelmet.debug.panelShot`).
    func debugShot() async {
        guard isOpen, let window, let primary = NSScreen.screens.first else {
            PelmetLog.log("panel: shot skipped — not open")
            return
        }
        // Room below for a right-click menu.
        var frame = window.frame.insetBy(dx: -40, dy: -40)
        frame = frame.union(frame.offsetBy(dx: 0, dy: -260))
        let rect = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        // The completion form: the async one traps when the capture hands
        // back neither an image nor an error (crashed Pelmet, 2026-10-09).
        guard #available(macOS 15.2, *), let image = await withCheckedContinuation({ (done: CheckedContinuation<CGImage?, Never>) in
            SCScreenshotManager.captureImage(in: rect) { image, _ in done.resume(returning: image) }
        }) else {
            PelmetLog.log("panel: shot failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let dir = URL(fileURLWithPath: NSString(string: "~/Library/Logs/Dimble/pass").expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wrote = (try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("panel.png"))) != nil
        PelmetLog.log("panel: shot \(wrote ? "written" : "not written") (\(image.width)×\(image.height))")
    }

    // MARK: - Pictures

    /// A relay's fresh picture of the item it pressed, taken once its menu
    /// is gone (ItemPress): whatever the press changed shows next open.
    func repicture(_ key: ItemID, frame: CGRect) async {
        guard let appState, let picture = await appState.transitions.pictureItem(key, frame: frame) else {
            PelmetLog.log("panel: \(key.rawValue) not re-pictured")
            return
        }
        pictures.store([key: picture])
        unpicturable[key] = nil
        PelmetLog.log("panel: \(key.rawValue) re-pictured")
        if isOpen { refresh() }
    }

    /// A concealed icon is in no tree the bar walks, so an app that switched
    /// its icon off while hidden kept its tile until the picture went stale,
    /// and a click on it opened nothing (Snib, CleanShot #26). The app's own
    /// extras bar still lists a concealed icon and lists none once it is
    /// off: where it disagrees with `noIcon`, the icon's section is pictured
    /// now, and the pass's walk has the last word.
    private func checkIconsGone() {
        guard let appState, iconCheck == nil, appState.screenRecordingGranted else { return }
        let live = Set((appState.snapshot?.items ?? []).filter { $0.frame != nil }.map(\.id.sectionKey))
        var keys: [String: [ItemID]] = [:]
        for item in [PelmetCore.Section.hidden, .alwaysHidden].flatMap(appState.editorItems(in:)) {
            let key = item.id.sectionKey
            guard let bundle = key.bundleID, !key.isSystemModule, !bundle.hasPrefix("com.apple."),
                  !PelmetBundle.ownIDs.contains(bundle), !extrasSayNothing.contains(bundle), !live.contains(key)
            else { continue }
            keys[bundle, default: []].append(key)
        }
        // An icon switched back on under the assertion parks, in no tree,
        // its app's extras bar included. The app is in front to switch it
        // on (the panel never takes that from it): its section is looked at
        // again, backing off (`revisitAfter`): an icon left off for good
        // costs a pass each time.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        inFrontSinceCheck.formIntersection(Set(noIcon.compactMap(\.bundleID)))
        for bundle in inFrontSinceCheck { revisitAfter[bundle] = nil }
        let now = Date()
        let revisit = noIcon.filter { key in
            guard let bundle = key.bundleID, inFrontSinceCheck.contains(bundle) || bundle == front else { return false }
            return lookedFor[key].map { now.timeIntervalSince($0) >= revisitAfter[bundle] ?? 1 } ?? true
        }
        let pids = keys.keys.reduce(into: [String: [pid_t]]()) { pids, bundle in
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier)
            if !running.isEmpty { pids[bundle] = running }
        }
        guard !pids.isEmpty || !revisit.isEmpty else { return }
        iconCheck = Task { @MainActor [weak self] in
            defer { self?.iconCheck = nil }
            let lists = pids.isEmpty ? [:] : await Self.listStatusItems(pids)
            guard let self, let appState = self.appState else { return }
            var said: [ItemID: Bool] = [:]
            for (bundle, listed) in lists {
                if listed {
                    self.extrasListed.insert(bundle)
                } else if !self.extrasListed.contains(bundle) {
                    continue
                }
                for key in keys[bundle] ?? [] where self.noIcon.contains(key) == listed { said[key] = listed }
            }
            guard !said.isEmpty || !revisit.isEmpty else { return }
            // The open's own pass first; one still lifting its cover refuses
            // the next.
            let started = Date()
            while self.passTask != nil || appState.transitions.passInFlight, Date().timeIntervalSince(started) < 6 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard self.passTask == nil else { return }
            // The open's pass may have settled some already, and looked
            // for the ones left out.
            said = said.filter { self.noIcon.contains($0.key) == $0.value }
            let again = revisit.filter { self.noIcon.contains($0) && (self.lookedFor[$0] ?? .distantPast) < now }
            let wanted = Set(said.keys).union(again)
            guard !wanted.isEmpty else { return }
            if !said.isEmpty {
                PelmetLog.log("panel: extras bars disagree — \(said.map { "\($0.key.rawValue) \($0.value ? "lists an icon" : "lists none")" }.sorted()), pictured to check")
            }
            if !again.isEmpty {
                PelmetLog.log("panel: \(again.map(\.rawValue).sorted()) left out, their app is or was in front, looked for again")
                self.inFrontSinceCheck.subtract(again.compactMap(\.bundleID))
            }
            self.extrasSaid = said
            self.picturePassIfNeeded(Array(wanted))
        }
    }

    /// Which of `wanted` a pass's walk found missing (`absent`) or back:
    /// true when a tile comes or goes. `counts` once per pass, at the walk.
    @discardableResult
    private func settleNoIcon(wanted: [ItemID], absent: Set<ItemID>, counts: Bool = false) -> Bool {
        let lookedAt = Date()
        for key in wanted where noIcon.contains(key) || absent.contains(key) { lookedFor[key] = lookedAt }
        if counts {
            for key in wanted {
                guard let bundle = key.bundleID else { continue }
                if absent.contains(key) {
                    revisitAfter[bundle] = noIcon.contains(key) ? min((revisitAfter[bundle] ?? 1) * 2, 60) : 1
                } else if noIcon.contains(key) {
                    revisitAfter[bundle] = nil
                }
            }
        }
        let backNow = noIcon.intersection(wanted).subtracting(absent)
        noIcon.subtract(backNow)
        let newlyMissing = absent.subtracting(noIcon)
        noIcon.formUnion(absent)
        guard !newlyMissing.isEmpty || !backNow.isEmpty else { return false }
        PelmetLog.log("panel: no icon in the bar, left out \(newlyMissing.map(\.rawValue).sorted())\(backNow.isEmpty ? "" : ", back \(backNow.map(\.rawValue).sorted())")")
        return true
    }

    /// Per bundle, whether any running copy lists a status item; a bundle
    /// with a copy whose accessibility doesn't answer is left out.
    @concurrent
    private static func listStatusItems(_ pids: [String: [pid_t]]) async -> [String: Bool] {
        pids.reduce(into: [:]) { lists, entry in
            let answers = entry.value.map(ItemEnumerator.listsStatusItem(pid:))
            if answers.contains(true) {
                lists[entry.key] = true
            } else if answers.allSatisfy({ $0 == false }) {
                lists[entry.key] = false
            }
        }
    }

    /// The pass, once, when the open panel (or the Settings preview) shows
    /// tiles with no picture. `done` runs once pictures were stored.
    func picturePassIfNeeded(_ missing: [ItemID], done: (@MainActor () -> Void)? = nil) {
        guard let appState, appState.screenRecordingGranted else { return }
        if passTask != nil {
            if let done { passWaiters.append(done) }
            return
        }
        let surface = ConcealGhostOverlay.surfaceSignature()
        if surface != unpicturableSurface {
            if !unpicturable.isEmpty {
                PelmetLog.log("panel: the wallpaper or appearance changed — \(unpicturable.count) tile(s) asked for again")
                unpicturable.removeAll()
            }
            unpicturableSurface = surface
        }
        var wanted = missing.filter { key in
            unpicturable[key].map { -$0.timeIntervalSinceNow >= ItemPictures.maxAge } ?? true
        }
        if isOpen {
            let fresh = wanted.filter { !askedThisOpen.contains($0) }
            if fresh.count < wanted.count, !askedAgainLogged {
                askedAgainLogged = true
                PelmetLog.log("panel: \(wanted.count - fresh.count) without a fresh picture already asked for this open, asked again next open")
            }
            wanted = fresh
            askedThisOpen.formUnion(wanted)
        }
        guard !wanted.isEmpty else { return }
        if let done { passWaiters.append(done) }
        let roster = appState.settings.sectionModel.roster
        let needsAlways = wanted.contains { roster.section(of: $0) == .alwaysHidden }
        let reveal: Set<PelmetCore.Section> = needsAlways ? [.hidden, .alwaysHidden] : [.hidden]
        // A pass that runs anyway looks again for icons it found missing,
        // in the sections it reveals.
        wanted += noIcon.filter { !wanted.contains($0) && reveal.contains(roster.section(of: $0)) }
        passTask = Task { @MainActor [weak self, weak appState] in
            guard let appState else { return }
            // The tiles come and go as soon as the reveal's walk is read,
            // the pictures follow when the pass is done.
            let found = await appState.transitions.picturePass(reveal, wanting: Set(wanted)) { [weak self] absent in
                guard let self, self.settleNoIcon(wanted: wanted, absent: absent, counts: true), self.isOpen else { return }
                self.refresh()
            }
            guard let self else { return }
            self.passTask = nil
            let waiters = self.passWaiters
            self.passWaiters = []
            defer { for waiter in waiters { waiter() } }
            // A pass that never saw the icons (the bar out, an idle Mac's
            // empty walk) says nothing about them: the next open tries again.
            guard let found else {
                PelmetLog.log("panel: pass saw no icons, \(wanted.count) wanted")
                for key in wanted { self.extrasSaid[key] = nil }
                return
            }
            self.pictures.store(found.pictures)
            self.settleNoIcon(wanted: wanted, absent: found.absent)
            // An extras bar the pass proved wrong is not asked again.
            for key in wanted {
                guard let listed = self.extrasSaid.removeValue(forKey: key), let bundle = key.bundleID else { continue }
                let wrong = listed ? found.absent.contains(key) : found.pictures[key] != nil
                if wrong, self.extrasSayNothing.insert(bundle).inserted {
                    PelmetLog.log("panel: \(bundle)'s extras bar said \(listed ? "an icon" : "none"), the bar disagrees: not asked again")
                }
            }
            let now = Date()
            // Only what the pass tried and missed waits out `maxAge`; a key
            // a skipped round never reached is asked for again next open.
            // One with no icon on the bar is `noIcon`'s, looked for again
            // when its app comes to the front.
            for key in found.failed.subtracting(found.absent) { self.unpicturable[key] = now }
            let lost = wanted.filter { found.pictures[$0] == nil }.map(\.rawValue)
            let again = max(0, lost.count - found.failed.count)
            PelmetLog.log("panel: pass pictured \(found.pictures.count) of \(wanted.count) wanted\(lost.isEmpty ? "" : " — none for \(lost)")\(again > 0 ? ", \(again) asked again next open" : "")")
            guard self.isOpen else { return }
            // A widen or an unfold while it ran can want more.
            let shown = self.refresh()
            self.picturePassIfNeeded(shown.missing)
        }
    }
}

/// The panel pinned to the window's top right, where the window is
/// anchored: the content changes a moment before the window takes its new
/// size, and centred it jumped by half the difference (the fold row and the
/// row above it, 2026-10-09). The zero minimums matter: without them the
/// frame grows to a taller panel and centres it all the same.
struct PanelHost: View {
    /// The hosting view's own space: what the drag measures the panel in.
    static let space = "panelHost"

    let panel: PanelView

    var body: some View {
        panel.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topTrailing)
            .coordinateSpace(name: Self.space)
    }
}

/// The panel's content. It takes the first click: a hover-opened panel isn't
/// key, and the press that would make it key must still pick a tile up.
private final class PanelHostingView: NSHostingView<PanelHost> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The column grip's host. It takes the first click: a hover-opened panel
/// isn't key, and the press that would make it key never reached the drag.
private final class GripHostingView: NSHostingView<PanelEdgeGrip> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A tracking area's owner: the pointer onto the panel and off it.
private final class PointerWatch: NSResponder {
    private let entered: () -> Void
    private let exited: () -> Void

    init(entered: @escaping () -> Void, exited: @escaping () -> Void) {
        self.entered = entered
        self.exited = exited
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { entered() }
    override func mouseExited(with event: NSEvent) { exited() }
}
