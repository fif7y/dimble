// MediaControls.swift — Pelmet items ("extras"): Pelmet-owned proxies for the
// system extras that macOS collateral-hides under any assertion, user
// shortcut buttons, and app launchers (a Pelmet icon that opens an app).
// Because Pelmet owns these NSStatusItems, hiding is plain `isVisible` per
// assigned section — no assertion involvement (asserting away Pelmet's bundle
// would take the chevron too).

import AppKit
import AVFoundation
import CoreAudio
import CoreMediaIO
import PelmetCore
import PelmetEngine
import UniformTypeIdentifiers

// MARK: - Media keys

enum MediaKey: Int32 {
    case playPause = 16  // NX_KEYTYPE_PLAY
    case next = 17       // NX_KEYTYPE_NEXT
    case previous = 18   // NX_KEYTYPE_PREVIOUS

    /// Posts the system-defined media key (down+up), same as the keyboard key.
    func send() {
        for down in [true, false] {
            let flags: UInt = down ? 0xA00 : 0xB00
            let data1 = Int((Int(self.rawValue) << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Manager

@MainActor
final class ExtrasManager {
    private weak var appState: AppState?
    private var items: [UUID: NSStatusItem] = [:]
    /// What each item's button last showed, by a key of the inputs that
    /// picked the image. Every `button.image` swap costs ~5ms of main
    /// thread on macOS 27 (replicant snapshot + scene IPC), and the reflow
    /// companion re-applies every item on every swap; an unchanged glyph
    /// is skipped (2026-09-21). A button whose image is nil (fresh item)
    /// always draws.
    private var glyphKeys: [UUID: String] = [:]
    /// The own items as the bar shows them: which are up, with which face.
    /// The blink cover's idle picture is only true of a bar whose own items
    /// read the same (Camera & mic's SharePlay face missing for 0.65s under
    /// the click's cover, 60fps burst 2026-09-25). A timestamp of the last
    /// change stood here: it moved on every show AND hide, so one hover
    /// reveal (extras up, then down again, the bar exactly as pictured)
    /// staled the picture for every clock click after it, each paying a
    /// ~250ms capture (#74, 2026-10-02).
    var barSignature: String {
        lastVisible.filter(\.value).keys
            .sorted { $0.uuidString < $1.uuidString }
            .map { "\($0.uuidString):\(glyphKeys[$0] ?? "")" }
            .joined(separator: "|")
    }

    private func setGlyph(_ item: NSStatusItem, id: UUID, key: String, make: () -> NSImage?) {
        guard let button = item.button else { return }
        if glyphKeys[id] == key, button.image != nil { return }
        button.image = make()
        glyphKeys[id] = key
    }
    private var specs: [UUID: ExtraItemSpec] = [:]
    private var lastVisible: [UUID: Bool] = [:]
    /// When each extra that is up was last shown. A show is no swap, so the
    /// walk can read the bar at rest from before it, and the walk behind a
    /// swap reads it joining the layout: the Apply count waits for a walk at
    /// rest after it (`ApplyCount.hasWalked`; Shortcuts moved to Visible
    /// read "= 0" until then, live test, 2026-10-13 20:24:38).
    private var shownAt: [UUID: Date] = [:]
    /// Every extra allows the native ⌘-drag off the bar; AppKit reports it
    /// as an `isVisible` flip (see `observeRemoval`).
    private var removalObservations: [UUID: NSKeyValueObservation] = [:]
    /// Attached ahead of an uncovered swap (see `preattach`): the companion's
    /// show only fades them, and a pending layout drop must leave them be.
    private var preattached: Set<UUID> = []
    private var cameraMicMonitor: CameraMicMonitor?
    /// Pelmet's own countdown, alive while a timer item exists.
    private var pelmetTimer: PelmetTimer?
    private var lastTimerActive = false
    /// The Clock app's timer, for the timer item to show while its own is idle.
    private var clockTimerStatus: ClockTimerStatus?
    /// Time Machine's state, alive while a Time Machine item exists.
    private var timeMachine: TimeMachineBackup?
    private var lastBackupRunning = false
    /// Which Focus is on, alive while a Focus item exists.
    private var focusStatus: FocusStatus?
    private var lastFocusActive = false
    /// Whether a SharePlay session with no call is live, alive while a
    /// Camera & mic item exists.
    private var sharePlayStatus: SharePlayStatus?
    /// The Live Activities running, alive while a Live Activities item exists
    /// or live mode is on with Screen Recording granted (the "Show Live
    /// Activities" setting): one watcher serves both.
    private var liveActivityStatus: LiveActivityStatus?
    private var lastLiveActivityActive = false
    /// Live mode on without Screen Recording: the grant lands in System
    /// Settings, where nothing tells Dimble, so it is read until it arrives.
    private var grantWait: Task<Void, Never>?
    /// One clock per media item drawing the animated bars (see ExtraGlyphs).
    private var animators: [UUID: ExtraAnimator] = [:]
    /// Play/pause state the media glyph shows. Click intent drives it (players
    /// keep the output device open while paused, so DeviceIsRunningSomewhere
    /// alone can't see a pause); real audio EDGES reconcile it when they do
    /// arrive — start means playing, device release means stopped.
    private var mediaPlaying = false
    private var lastAudioOutputActive = false
    /// Edge tracking for the camera/mic indicator's placement walk.
    private var lastCameraIndicatorVisible = false
    /// Debounces the activation edge before queuing the placement walk.
    private var cameraPlacementDebounce: Task<Void, Never>?
    /// App launchers with the "while running" rule: the running edge (not the
    /// section reveal edge) is what re-enters layout and needs a placement.
    private var lastRunning: [UUID: Bool] = [:]
    /// Menu-bar agent apps post no launch notification; KVO on the running
    /// list sees every activation policy (same lesson as AppState's relaunch
    /// observer, 2026-09-09).
    private var runningAppsObservation: NSKeyValueObservation?
    /// Extras sitting out of the bar (camera off, no audio, app not running)
    /// attached invisibly for the length of an Apply pass so they have a
    /// slot to drag — see `attachForApply`.
    private var attachedForApply: Set<UUID> = []
    /// Extras out of the bar to make room for the chevron behind Apple's «
    /// (#81), with the width each gave back, in the order they went.
    /// Runtime only: `apply` reads them as down until they come back.
    private var yielded: [(id: UUID, width: CGFloat)] = []
    /// The latest extra back from making room, with the width it went out
    /// at: `yieldRestoredAgain` takes it out again when it didn't fit.
    private var lastRestored: (id: UUID, width: CGFloat)?

    init(appState: AppState) {
        self.appState = appState
    }

    static func itemID(for spec: ExtraItemSpec) -> ItemID {
        .status(
            bundle: PelmetBundle.mainID,
            title: spec.itemTitle
        )
    }

    /// All ItemIDs the editor should represent even when invisible.
    var managedItemIDs: [ItemID] {
        specs.values.map(Self.itemID(for:))
    }

    /// Whether this extra is actually in the bar right now. The gated kinds
    /// sit in a section but only appear while live (media controls with
    /// audio playing, the camera indicator with a camera on, a launcher's app
    /// running), so a caller that needs a real AX item — the boot adoption
    /// wait — has to ask rather than infer it from the section.
    func isShowing(_ id: ItemID) -> Bool {
        specs.contains { lastVisible[$0.key] == true && Self.itemID(for: $0.value) == id }
    }

    /// When the extra under `key` (canonical) was last shown; nil while it
    /// is down.
    func shownAt(_ key: ItemID) -> Date? {
        specID(for: key).flatMap { shownAt[$0] }
    }

    /// Whether this extra would be in the bar with its section out: the
    /// gated kinds only while live, as `apply` decides. The panel asks, since
    /// it draws a section without putting it on the bar. True for a key
    /// that is no extra.
    func wouldShow(_ id: ItemID) -> Bool {
        guard let spec = specs.values.first(where: { Self.itemID(for: $0).sectionKey == id.sectionKey }) else { return true }
        switch spec.kind {
        case .cameraMicIndicator:
            return lastCameraIndicatorVisible
        case .liveActivity:
            return lastLiveActivityActive
        case .mediaControls:
            return spec.resolvedShowRule != .whenActive || (cameraMicMonitor?.mediaRelevant ?? true)
        case .appLauncher:
            return spec.resolvedShowRule != .whenActive || Self.isRunning(spec)
        case .timer:
            return spec.resolvedShowRule != .whenActive || (pelmetTimer?.isActive ?? false)
        case .focus:
            return !spec.isOnlyWhileActive || focusStatus?.active != nil
        case .timeMachine:
            return !spec.isOnlyWhileActive || (timeMachine?.status.running ?? false)
        default:
            return true
        }
    }

    /// Extras Show in Menu Bar brought out on their own: each rides its rule
    /// as if its section were out, until `releaseAlone`. They hide by their
    /// own visibility, not the assertion, so the engine's item reveal can't
    /// bring them (AppState.itemsInBar holds the set the rehide machine ends).
    private var shownAlone: Set<UUID> = []

    enum AloneOutcome {
        /// It can come out on its own.
        case ready
        /// It is in the bar already.
        case showing
        /// Its own rule keeps it out whatever its section does (media with
        /// nothing playing, a launcher whose app is not running, a camera
        /// that is off): there is nothing to bring out.
        case gated
    }

    private func specID(for key: ItemID) -> UUID? {
        specs.first { Self.itemID(for: $0.value).sectionKey == key.sectionKey }?.key
    }

    /// Whether this key is one of the extras; separators and the chevron are not.
    func manages(_ key: ItemID) -> Bool { specID(for: key) != nil }

    /// Nil for a key that is no extra.
    func aloneOutcome(for key: ItemID) -> AloneOutcome? {
        guard let id = specID(for: key), let spec = specs[id] else { return nil }
        if lastVisible[id] == true {
            // Out on its show rule while its section is concealed: the press
            // still takes it, so it stays when the rule ends.
            return outOnItsRuleAlone(id, spec) ? .ready : .showing
        }
        return wouldShow(key) ? .ready : .gated
    }

    private func outOnItsRuleAlone(_ id: UUID, _ spec: ExtraItemSpec) -> Bool {
        guard spec.comesOutWhileActive, !shownAlone.contains(id), let appState else { return false }
        let section = appState.settings.sectionModel.section(of: Self.itemID(for: spec))
        return section != .visible && !appState.revealedSectionsForExtras.contains(section)
    }

    func showAlone(_ keys: Set<ItemID>) {
        for key in keys { specID(for: key).map { _ = shownAlone.insert($0) } }
        applyCurrent()
    }

    /// Only forgets them: whoever calls this has a swap of its own coming,
    /// and the engine's companion hides the extras inside it with the rest.
    /// Applying here ran every Hidden extra's ghost one converge early.
    func forgetAlone(_ keys: Set<ItemID>) {
        for key in keys { specID(for: key).map { _ = shownAlone.remove($0) } }
    }

    /// Forgets them and hides them now, for a release with no swap behind it.
    func releaseAlone(_ keys: Set<ItemID>) {
        guard !keys.isEmpty else { return }
        forgetAlone(keys)
        applyCurrent()
    }

    func sync(with newSpecs: [ExtraItemSpec]) {
        Self.iconCache.removeAll(keepingCapacity: true)
        let wanted = Set(newSpecs.map(\.id))
        for (id, item) in items where !wanted.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            shownAlone.remove(id)
            items.removeValue(forKey: id)
            glyphKeys.removeValue(forKey: id)
            specs.removeValue(forKey: id)
            lastVisible.removeValue(forKey: id)
            shownAt.removeValue(forKey: id)
            lastRunning.removeValue(forKey: id)
            removalObservations.removeValue(forKey: id)
            animators[id]?.tearDown()
            animators.removeValue(forKey: id)
        }
        for spec in newSpecs {
            let styleChanged = specs[spec.id].map { $0.style != spec.style } ?? false
            specs[spec.id] = spec
            if items[spec.id] == nil {
                items[spec.id] = makeItem(for: spec)
            }
            // The editor board shows the real glyph: the drawn AirDrop mark
            // always, the bars when media is animated, the symbol otherwise.
            if spec.kind == .appLauncher, spec.symbol == nil,
               let icon = Self.appIcon(for: spec, size: 20) {
                ItemImageCache.registerPelmetItem(title: spec.itemTitle, image: icon)
            } else if spec.kind == .airdrop {
                ItemImageCache.registerPelmetItem(
                    title: spec.itemTitle, image: ExtraGlyph.airdrop
                )
            } else if spec.kind == .mediaControls, spec.resolvedStyle == .animated {
                ItemImageCache.registerPelmetItem(
                    title: spec.itemTitle, image: ExtraGlyph.mediaBars(t: 0, level: 1, animated: false)
                )
            } else {
                ItemImageCache.unregisterPelmetItemImage(title: spec.itemTitle)
                ItemImageCache.registerPelmetItem(
                    title: spec.itemTitle, symbol: Self.symbol(for: spec)
                )
            }
            if styleChanged, let item = items[spec.id] {
                animators[spec.id]?.tearDown()
                animators.removeValue(forKey: spec.id)
                refreshGlyph(item, spec: spec)
            }
            // The glyph is editable (launcher icon picker), so refresh the
            // existing button too — sync only builds the item once.
            if spec.kind == .appLauncher, let button = items[spec.id]?.button {
                button.image = Self.launcherImage(for: spec, size: 18)
            }
        }
        // Only a "while running" launcher depends on the running list; an
        // "always" launcher hides purely by section. This KVO fires for
        // every app launch and quit on the machine, so don't hold it for
        // launchers that would ignore it.
        let needsRunningObserver = newSpecs.contains {
            $0.kind == .appLauncher && $0.resolvedShowRule == .whenActive
        }
        if needsRunningObserver, runningAppsObservation == nil {
            runningAppsObservation = NSWorkspace.shared.observe(
                \.runningApplications, options: [.new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.applyCurrent() }
            }
        } else if !needsRunningObserver {
            runningAppsObservation = nil
        }
        if newSpecs.contains(where: { $0.kind == .timer }) {
            if pelmetTimer == nil {
                let timer = PelmetTimer()
                timer.onChange = { [weak self] in self?.timerChanged() }
                pelmetTimer = timer
                let clock = ClockTimerStatus()
                clock.onChange = { [weak self] in self?.pelmetTimer?.clock = self?.clockTimerStatus?.current }
                clockTimerStatus = clock
                clock.start()
            }
        } else if let timer = pelmetTimer {
            timer.cancel()
            pelmetTimer = nil
            clockTimerStatus?.stop()
            clockTimerStatus = nil
        }
        if newSpecs.contains(where: { $0.kind == .timeMachine }) {
            if timeMachine == nil {
                let backup = TimeMachineBackup()
                backup.onChange = { [weak self] in self?.timeMachineChanged() }
                timeMachine = backup
                backup.start()
            }
        } else if let backup = timeMachine {
            backup.stop()
            timeMachine = nil
        }
        if newSpecs.contains(where: { $0.kind == .focus }) {
            if focusStatus == nil {
                let status = FocusStatus()
                status.onChange = { [weak self] in self?.focusChanged() }
                focusStatus = status
                status.start()
            }
        } else if let status = focusStatus {
            status.stop()
            focusStatus = nil
        }
        syncLiveActivityWatcher()
        if newSpecs.contains(where: { $0.kind == .cameraMicIndicator }) {
            if sharePlayStatus == nil {
                let status = SharePlayStatus()
                status.onChange = { [weak self] in self?.applyCurrent() }
                sharePlayStatus = status
                status.start()
            }
        } else if let status = sharePlayStatus {
            status.stop()
            sharePlayStatus = nil
        }
        let needsCameraMonitor = newSpecs.contains {
            $0.kind == .cameraMicIndicator || $0.kind == .mediaControls
        }
        if needsCameraMonitor, cameraMicMonitor == nil {
            cameraMicMonitor = CameraMicMonitor { [weak self] in
                self?.applyCurrent()
            }
        } else if !needsCameraMonitor {
            cameraMicMonitor?.stop()
            cameraMicMonitor = nil
        }
        applyCurrent()
    }

    /// Applies section visibility. Hiding collapses the item's LENGTH instead
    /// of toggling isVisible — isVisible plays its own slide animation on a
    /// different clock than the assertion reflow; a width collapse rides the
    /// same bar reflow and reads as one motion. The camera/mic indicator
    /// overrides its section while hardware is live — an indicator that hides
    /// when active would be lying.
    func apply(
        model: SectionModel,
        revealed: Set<PelmetCore.Section>,
        systemCameraPillVisible: Bool
    ) {
        yielded.removeAll { specs[$0.id] == nil }
        for (id, item) in items {
            guard let spec = specs[id], !attachedForApply.contains(id) else { continue }
            let section = model.section(of: Self.itemID(for: spec))
            // Shown on its own, the extra reads as if its section were out:
            // its own rule below (media playing, app running) still decides.
            var visible = section == .visible || revealed.contains(section) || shownAlone.contains(id)
            switch spec.kind {
            case .cameraMicIndicator:
                // Pure indicator, like Apple's: exists ONLY while hardware is
                // live, or a SharePlay session with no call (section decides
                // where it appears, not whether). Defers to the system pill,
                // or Apple's SharePlay icon, when that one is on screen.
                let active = (cameraMicMonitor?.isActive ?? false) || (sharePlayStatus?.isLive ?? false)
                visible = active && !systemCameraPillVisible && !(appState?.systemSharePlayVisible ?? false)
                updateCameraSymbol(item, spec: spec)
                // Re-entering layout (isVisible flip) parks the item wherever
                // the agent decides, not at its model slot. Never drag here:
                // the activation is app-driven (Sconce opening the camera,
                // 2026-08-31) and the synthetic ⌘-drag hijacked the pointer
                // mid-task. Debounce the edge — the system pill takes over
                // within ~50ms and hides us again — then queue the walk for
                // the next reveal settle.
                let itemID = Self.itemID(for: spec)
                if visible, !lastCameraIndicatorVisible {
                    cameraPlacementDebounce?.cancel()
                    cameraPlacementDebounce = Task { [weak self] in
                        try? await Task.sleep(for: AppTiming.cameraIndicatorPlaceDebounce)
                        guard let self, !Task.isCancelled,
                              self.lastCameraIndicatorVisible else { return }
                        // The indicator is on screen: through the Apply
                        // door now (docs/CORE-SETS.md §Own items).
                        self.appState?.placeOwnItemSoon(itemID)
                    }
                } else if !visible, lastCameraIndicatorVisible {
                    cameraPlacementDebounce?.cancel()
                    appState?.cancelOwnItemPlacement(itemID)
                }
                lastCameraIndicatorVisible = visible
            case .liveActivity:
                // An indicator like Camera & mic: in the bar only while an
                // activity runs, its section deciding where, not whether.
                // On screen (Visible, or its section revealed) it is placed
                // now, like the Timer: left to the next reveal, it sat at the
                // agent's slot with Apply (1) up for 20 minutes (Gab,
                // 2026-10-29). Concealed, the next reveal settle places it.
                let active = !(liveActivityStatus?.active.isEmpty ?? true)
                let sectionVisible = visible
                visible = active
                updateLiveActivityGlyph(item, spec: spec)
                let itemID = Self.itemID(for: spec)
                if active, !lastLiveActivityActive {
                    if sectionVisible {
                        appState?.placeOwnItemSoon(itemID)
                    } else {
                        appState?.placeOwnItemAtNextReveal(itemID)
                    }
                } else if !active, lastLiveActivityActive {
                    appState?.cancelOwnItemPlacement(itemID)
                }
                lastLiveActivityActive = active
            case .mediaControls:
                let audioActive = cameraMicMonitor?.audioOutputActive ?? false
                if audioActive != lastAudioOutputActive {
                    lastAudioOutputActive = audioActive
                    mediaPlaying = audioActive
                }
                updateMediaSymbol(item, spec: spec)
                // "Always": a play/pause button that rides its section like
                // AirDrop. "While playing": an indicator, like the camera's
                // and Apple's Now Playing — in its section only while
                // media-relevant (playing, or within the post-playback linger
                // so pause doesn't swallow resume), gone otherwise (Gab,
                // 2026-10-12: not a "Show when it matters" rule).
                if spec.resolvedShowRule == .whenActive {
                    visible = visible && (cameraMicMonitor?.mediaRelevant ?? true)
                    // Same re-entry hazard as the camera pill: audio
                    // starting (or the linger expiring and resuming) puts
                    // the item back in layout at the agent's slot, not the
                    // model's.
                    let itemID = Self.itemID(for: spec)
                    if visible, lastVisible[id] != true {
                        appState?.placeOwnItemSoon(itemID)
                    } else if !visible, lastVisible[id] == true {
                        appState?.cancelOwnItemPlacement(itemID)
                    }
                }
            case .appLauncher:
                // "While running" mirrors the app's own icon; "Always" is a
                // launcher and hides purely by section, like AirDrop.
                let running = Self.isRunning(spec)
                if spec.resolvedShowRule == .whenActive {
                    visible = visible && running
                    // The running edge re-enters layout at the agent's slot,
                    // not the model's — same hazard as the media button.
                    // Visible right now (section revealed): place at once,
                    // the user launched the app and is looking at the bar.
                    // Concealed: the next reveal settle places it. Section
                    // reveals themselves don't queue: those ride the reflow.
                    let itemID = Self.itemID(for: spec)
                    if running, lastRunning[id] != true {
                        if visible {
                            appState?.placeOwnItemSoon(itemID)
                        } else {
                            appState?.placeOwnItemAtNextReveal(itemID)
                        }
                    } else if !running, lastRunning[id] == true {
                        appState?.cancelOwnItemPlacement(itemID)
                    }
                }
                lastRunning[id] = running
            case .airdrop:
                updateAirDropGlyph(item, spec: spec)
            case .timer:
                // Section-governed while idle; a counting (or ringing) timer
                // is an indicator and stays in the bar whatever its section.
                // "While a timer runs": gone while idle, wherever it sits
                // (a Clock or Siri timer brings it).
                let active = pelmetTimer?.isActive ?? false
                let sectionVisible = visible
                visible = (spec.resolvedShowRule == .whenActive ? false : visible) || active
                updateTimerGlyph(item, spec: spec)
                let itemID = Self.itemID(for: spec)
                if active, !lastTimerActive {
                    // The user just clicked it: the section reveal isn't
                    // what put it in layout, so place it now if the bar is
                    // looking, else on the next reveal settle.
                    if sectionVisible {
                        appState?.placeOwnItemSoon(itemID)
                    } else {
                        appState?.placeOwnItemAtNextReveal(itemID)
                    }
                } else if !active, lastTimerActive {
                    appState?.cancelOwnItemPlacement(itemID)
                }
                lastTimerActive = active
            case .timeMachine:
                updateTimeMachineGlyph(item, spec: spec)
                let running = timeMachine?.status.running ?? false
                // "When active": also out on the bar while a backup runs,
                // from whatever section it sits in. "While backing up": gone
                // while idle, like the Timer's "While a timer runs".
                if spec.comesOutWhileActive {
                    visible = ruleVisibility(id, spec, active: running, sectionVisible: spec.isOnlyWhileActive ? false : visible)
                }
                lastBackupRunning = running
            case .focus:
                // The moon rides its section, idle it opens the Focus panel.
                // "When active": also out on the bar while a Focus is on,
                // from whatever section it sits in. "While a Focus is on":
                // gone while idle, the way Apple's "When Active" is.
                let active = focusStatus?.active != nil
                if spec.comesOutWhileActive {
                    visible = ruleVisibility(id, spec, active: active, sectionVisible: spec.isOnlyWhileActive ? false : visible)
                }
                updateFocusGlyph(item, spec: spec)
                lastFocusActive = active
            case .shortcut, .userSwitching, .shortcutsMenu, .siri, .quickNote:
                break
            }
            if let index = yielded.firstIndex(where: { $0.id == id }) {
                // Its own rule brings it out (a timer started, a Focus came
                // on): an indicator never stays out for the chevron.
                if ruleForcesShow(spec) { yielded.remove(at: index) } else { visible = false }
            }
            setVisible(visible, for: id, item: item)
            // A hidden glyph keeps its last frame and stops ticking.
            animators[id]?.paused = !visible
        }
        // Brought out alone but out of the bar now (media stopped, the app
        // quit, the Focus ended): nothing of it is left to hold the reveal.
        let left = shownAlone.filter { specs[$0] != nil && lastVisible[$0] != true && !attachedForApply.contains($0) }
        if !left.isEmpty {
            shownAlone.subtract(left)
            appState?.ownItemsLeftBar(Set(left.compactMap { specs[$0].map { Self.itemID(for: $0).sectionKey } }))
        }
    }

    /// A rule-on extra sits in its section like any icon and comes out on its
    /// own while its thing happens (#86), the way Battery does and the Timer
    /// does while it counts. The rule never takes it away: a Focus in Hidden
    /// with no Focus on waits in Hidden (Gab, 2026-10-12). A press
    /// (`shownAlone`, in `sectionVisible`) holds it past the rule's end, and
    /// the rule past the press's release. Out alone it re-enters layout at
    /// the agent's slot, not the model's, so the next reveal settle places
    /// it; a section reveal rides the reflow.
    private func ruleVisibility(_ id: UUID, _ spec: ExtraItemSpec, active: Bool, sectionVisible: Bool) -> Bool {
        let visible = sectionVisible || active
        let itemID = Self.itemID(for: spec)
        if visible, !sectionVisible, lastVisible[id] != true {
            appState?.placeOwnItemAtNextReveal(itemID)
        } else if !visible, lastVisible[id] == true {
            appState?.cancelOwnItemPlacement(itemID)
        }
        return visible
    }

    /// An own extra that is out of the bar has no slot, so Apply could not
    /// move it: a Camera moved in the editor while the camera was off only
    /// found its slot at the next camera-on edge (2026-09-20). For the pass,
    /// every idle extra joins the layout at alpha 0 (the agent gives it the
    /// slot it remembers), gets dragged like any icon, and leaves again in
    /// `detachAfterApply`; its next real entry lands at the new slot. Only
    /// the extras the edits `touch` join: each one is a blank slot while it
    /// is there. Never one out to make room for the chevron: back for the
    /// pass, it crowded the bar it left (live test, 2026-10-19 20:29).
    func attachForApply(touched: (ItemID) -> Bool) -> [ItemID] {
        var attached: [ItemID] = []
        for (id, item) in items where lastVisible[id] != true && !preattached.contains(id)
            && !yielded.contains(where: { $0.id == id }) {
            guard let spec = specs[id], touched(Self.itemID(for: spec)) else { continue }
            StatusItemFader.attach(item, shownLength: Self.shownLength(for: spec))
            attachedForApply.insert(id)
            attached.append(Self.itemID(for: spec))
        }
        return attached
    }

    func detachAfterApply() {
        for id in attachedForApply {
            items[id]?.length = 0
            items[id]?.isVisible = false
        }
        attachedForApply.removeAll()
        applyCurrent()
    }

    /// Section-governed items about to be revealed UNCOVERED join the layout
    /// now, invisible, so the swap changes no layout and the third-party
    /// icons fade in place (see `StatusItemFader.attach`). The companion's
    /// `apply` then only runs their fade. Returns what it attached so the
    /// caller can wait for the agent to place them.
    func preattach(model: SectionModel, revealing: Set<PelmetCore.Section>) -> [NSStatusItem] {
        var attached: [NSStatusItem] = []
        for (id, item) in items {
            guard let spec = specs[id], lastVisible[id] != true else { continue }
            switch spec.kind {
            case .airdrop, .shortcut, .userSwitching, .shortcutsMenu, .siri, .quickNote: break
            case .timer:
                // Counting: already in the bar on its own. Idle under
                // "While a timer runs": stays out.
                guard !(pelmetTimer?.isActive ?? false), spec.resolvedShowRule == .always else { continue }
            case .focus, .timeMachine:
                // Each rides its section under the card's rule; one already
                // out on its rule was skipped above. Idle under "only while
                // active": stays out.
                guard !spec.isOnlyWhileActive else { continue }
            case .mediaControls:
                // Audio-driven unless it always shows.
                guard spec.resolvedShowRule == .always else { continue }
            case .appLauncher:
                // The running edge has its own placement walk; only a plain
                // launcher (or one already running) rides the section.
                guard spec.resolvedShowRule != .whenActive || Self.isRunning(spec) else { continue }
            case .cameraMicIndicator, .liveActivity: continue  // driven by what runs
            }
            guard revealing.contains(model.section(of: Self.itemID(for: spec))) else { continue }
            StatusItemFader.attach(item, shownLength: Self.shownLength(for: spec))
            preattached.insert(id)
            attached.append(item)
        }
        return attached
    }

    /// Two-phase hide: width-collapse rides the same bar reflow as the
    /// assertion (matched animation), then after the reflow settles the item
    /// leaves layout entirely — zero-length items still reserve their built-in
    /// spacing, which reads as a dead gap next to the chevron.
    private func setVisible(_ visible: Bool, for id: UUID, item: NSStatusItem) {
        if !visible, lastVisible[id] != true, preattached.remove(id) != nil {
            // Attached ahead of a reveal that never came: leave layout again, unseen.
            item.isVisible = false
            return
        }
        guard lastVisible[id] != visible else { return }
        lastVisible[id] = visible
        shownAt[id] = visible ? Date() : nil
        if visible { appState?.ownItemShown() }
        let wasPreattached = preattached.remove(id) != nil
        PelmetLog.log("extras: \(specs[id]?.itemTitle ?? "?") → \(visible ? (wasPreattached ? "fade (attached ahead)" : "show") : "hide (ghost)")")
        // Runs as the engine's reflow companion, so timing coincides with the
        // assertion swap — choreography and constants live in StatusItemFader.
        let stillCurrent: @MainActor () -> Bool = { [weak self] in
            self?.lastVisible[id] == visible && self?.preattached.contains(id) != true
        }
        if visible, wasPreattached {
            StatusItemFader.fadeInAfterGlide(item, shownAlpha: 1, stillCurrent: stillCurrent)
            return
        }
        StatusItemFader.setVisible(
            visible,
            item: item,
            shownLength: specs[id].map(Self.shownLength(for:)) ?? NSStatusItem.squareLength,
            shownAlpha: 1,
            stillCurrent: stillCurrent
        )
    }

    // MARK: Making room for the chevron (#81)

    /// The extras out of the bar for the chevron, in the order they went.
    var yieldedKeys: [ItemID] {
        yielded.compactMap { specs[$0.id].map(Self.itemID(for:)) }
    }

    /// Takes the extra nearest the chevron out of the bar: one in Visible,
    /// up on its section alone. Indicators keep their place (a camera that
    /// is on, a counting timer), as does one brought out alone. Its key, nil
    /// when none can go.
    func yieldOne() -> ItemID? {
        let next = items.compactMap { id, item -> (id: UUID, frame: NSRect)? in
            guard canYield(id), let frame = item.button?.window?.frame, frame.width > 0 else { return nil }
            return (id, frame)
        }.min { $0.frame.minX < $1.frame.minX }
        guard let next, let spec = specs[next.id] else { return nil }
        yielded.append((next.id, next.frame.width))
        PelmetLog.log("extras: \(spec.itemTitle) out to make room for the chevron (\(Int(next.frame.width))pt)")
        applyCurrent()
        return Self.itemID(for: spec)
    }

    /// Up in Visible on its section alone, and not out already: an
    /// indicator, or one brought out alone, keeps its place.
    private func canYield(_ id: UUID) -> Bool {
        guard let appState, let spec = specs[id], lastVisible[id] == true, !shownAlone.contains(id),
              !yielded.contains(where: { $0.id == id }), spec.kind != .cameraMicIndicator,
              !ruleForcesShow(spec) else { return false }
        return appState.settings.sectionModel.section(of: Self.itemID(for: spec)) == .visible
    }

    /// Out on its own rule whatever its section: a counting timer, a Focus
    /// or a backup "when active". Such an extra never yields.
    private func ruleForcesShow(_ spec: ExtraItemSpec) -> Bool {
        switch spec.kind {
        case .timer: return pelmetTimer?.isActive ?? false
        case .focus: return spec.comesOutWhileActive && focusStatus?.active != nil
        case .timeMachine: return spec.comesOutWhileActive && (timeMachine?.status.running ?? false)
        case .liveActivity: return !(liveActivityStatus?.active.isEmpty ?? true)
        default: return false
        }
    }

    /// Brings back the latest extra out of the bar that fits in `room`
    /// (`ChevronTrap.restorable`). Its key, nil when none fits.
    func restoreYielded(room: CGFloat, failedRoom: CGFloat?) -> ItemID? {
        guard let index = ChevronTrap.restorable(widths: yielded.map(\.width), room: room, failedRoom: failedRoom),
              let spec = specs[yielded[index].id] else { return nil }
        lastRestored = yielded.remove(at: index)
        PelmetLog.log("extras: \(spec.itemTitle) back, the chevron has room (\(Int(room))pt)")
        applyCurrent()
        return Self.itemID(for: spec)
    }

    /// Takes the extra that just came back out again: the bar had no room
    /// for it after all (`room` was short). Its key, nil when it can't go
    /// (`canYield`: a timer that started counting meanwhile stays).
    func yieldRestoredAgain(shortRoom room: CGFloat) -> ItemID? {
        guard let restored = lastRestored, canYield(restored.id), let spec = specs[restored.id] else { return nil }
        lastRestored = nil
        yielded.append(restored)
        PelmetLog.log("extras: \(spec.itemTitle) out again, \(Int(room))pt was short")
        applyCurrent()
        return Self.itemID(for: spec)
    }

    /// No chevron left to make room for (its icon is off, the bar has no
    /// notch to measure the room by): every extra comes back.
    func restoreAllYielded() {
        lastRestored = nil
        guard !yielded.isEmpty else { return }
        yielded.removeAll()
        PelmetLog.log("extras: back from making room for the chevron")
        applyCurrent()
    }

    private func applyCurrent() {
        guard let appState else { return }
        apply(
            model: appState.settings.sectionModel,
            revealed: appState.revealedSectionsForExtras,
            systemCameraPillVisible: appState.systemCameraPillVisible
        )
    }

    // MARK: Item construction

    /// Square for glyph-only items; the timer grows with its countdown, Live
    /// Activities with their count.
    private static func shownLength(for spec: ExtraItemSpec) -> CGFloat {
        spec.kind == .timer || spec.kind == .liveActivity ? NSStatusItem.variableLength : NSStatusItem.squareLength
    }

    private func makeItem(for spec: ExtraItemSpec) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Self.shownLength(for: spec))
        item.autosaveName = spec.itemTitle
        if let button = item.button {
            if spec.kind == .appLauncher, let icon = Self.launcherImage(for: spec, size: 18) {
                button.image = icon
            } else if spec.kind == .airdrop {
                button.image = ExtraGlyph.airdrop
            } else {
                button.image = NSImage(
                    systemSymbolName: Self.symbol(for: spec),
                    accessibilityDescription: spec.itemTitle
                )
            }
            // The menu bar is TALLER on the built-in (notched) display than
            // on an external one, and AppKit clips an oversized status image
            // instead of fitting it — a launcher's app icon rendered as a
            // cropped square on Gab's LG (2026-09-10). Let the button shrink
            // it to whatever box that screen's bar gives us.
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Explicit AX title = the engine's item identity. Without it the
            // enumerator falls back to "Item-0" and every Pelmet item collides.
            button.setAccessibilityTitle(spec.itemTitle)
        }
        // Every extra may be dragged off the bar, and that drag must be a
        // per-item removal: without `.removalAllowed`, macOS 27 answers a
        // drag-out by disallowing the whole app in "Allow in the Menu Bar"
        // (2026-09-14), and a Focus item dropped short of that just slid to
        // the far left (2026-09-16).
        item.behavior = .removalAllowed
        observeRemoval(of: item, for: spec)
        return item
    }

    /// The native ⌘-drag off the bar: AppKit hides the item (`isVisible`
    /// false) and persists that under its autosave name — with nothing
    /// listening the launcher stayed in Settings and healed back on the next
    /// reveal (Comet, 2026-09-14). Pelmet's own hides flip `lastVisible`
    /// first, so a false arriving while it still reads true is the user's
    /// hand: drop the spec — the launcher's Remove, the toggle off for a
    /// singleton kind.
    private func observeRemoval(of item: NSStatusItem, for spec: ExtraItemSpec) {
        removalObservations[spec.id] = item.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let item = self.items[spec.id], !item.isVisible,
                      self.lastVisible[spec.id] == true,
                      let appState = self.appState else { return }
                PelmetLog.log("extras: \(spec.itemTitle) dragged off the bar → off")
                appState.settings.extraItems.removeAll { $0.id == spec.id }
                appState.settingsChanged()
            }
        }
    }

    static func symbol(for spec: ExtraItemSpec) -> String {
        switch spec.kind {
        case .mediaControls: "playpause.fill"
        case .cameraMicIndicator: "video.fill"
        case .airdrop: Self.airdropSymbol
        case .shortcut: spec.symbol ?? "bolt.fill"
        case .appLauncher: spec.symbol ?? "app.dashed"
        case .timer: "timer"
        case .userSwitching: "person.crop.circle"
        case .shortcutsMenu: "square.2.layers.3d.top.filled"
        case .timeMachine: ExtraGlyph.timeMachineSymbol
        case .siri: "siri"
        case .focus: "moon.fill"
        case .quickNote: "note.text"
        case .liveActivity: liveActivitySymbol
        }
    }

    /// Live Activities whose app the Mac doesn't have (the iPhone's, which
    /// is most of them) wear the platter Apple draws them in.
    static let liveActivitySymbol = "platter.filled.top.iphone"

    // MARK: App launchers

    /// A launcher's bar glyph: the SF Symbol the user picked (template, so
    /// the bar tints it like any other icon), else the app's own icon.
    /// Symbols draw a couple of points smaller than the app-icon box — a
    /// glyph fills its frame edge to edge where an app icon has its own
    /// padding, so equal box sizes read as a bigger icon (Gab, 2026-09-09).
    static func launcherImage(for spec: ExtraItemSpec, size: CGFloat) -> NSImage? {
        if let symbol = spec.symbol {
            let image = NSImage(
                systemSymbolName: symbol, accessibilityDescription: spec.appName
            )?.withSymbolConfiguration(.init(pointSize: size * 0.82, weight: .regular))
            image?.isTemplate = true
            return image
        }
        return appIcon(for: spec, size: size)
    }

    /// Glyphs offered by the launcher icon picker, filtered to what this
    /// system can actually draw (a missing symbol would render an empty
    /// cell). Ordered loosely by kind — neutral shapes first, then objects.
    static let launcherSymbols: [String] = [
        "star.fill", "heart.fill", "bolt.fill", "flame.fill", "sparkles", "moon.fill",
        "sun.max.fill", "cloud.fill", "drop.fill", "leaf.fill", "circle.fill", "square.fill",
        "triangle.fill", "diamond.fill", "hexagon.fill", "seal.fill", "app.fill", "capsule.fill",
        "bell.fill", "flag.fill", "tag.fill", "bookmark.fill", "pin.fill", "paperclip",
        "link", "key.fill", "lock.fill", "shield.fill", "gearshape.fill", "hammer.fill",
        "wrench.and.screwdriver.fill", "slider.horizontal.3", "terminal.fill", "cpu", "network", "wifi",
        "antenna.radiowaves.left.and.right", "globe", "message.fill", "envelope.fill", "phone.fill", "video.fill",
        "camera.fill", "mic.fill", "headphones", "music.note", "play.fill", "waveform",
        "folder.fill", "doc.fill", "tray.fill", "archivebox.fill", "externaldrive.fill", "cart.fill",
        "creditcard.fill", "chart.bar.fill", "calendar", "clock.fill", "eye.fill", "magnifyingglass",
        "person.fill", "brain.head.profile", "paintbrush.fill", "paintpalette.fill", "wand.and.stars", "scissors",
        "pencil", "checkmark.circle.fill", "command", "option",
    ].filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

    /// Rendered app icons, keyed by bundle id and point size. Both the
    /// launcher row and every cell of the icon picker ask for one from a
    /// SwiftUI body, and each miss was a LaunchServices lookup plus a
    /// disk-backed icon read — per render, not per change. Cleared by
    /// `sync`, so an edit still re-reads at the same granularity as before.
    private static var iconCache: [String: NSImage] = [:]

    /// The app's real icon (installed copy, running or not), sized for the
    /// bar or the editor tile. nil when the app is gone — the dashed-app
    /// symbol stands in for it.
    static func appIcon(for spec: ExtraItemSpec, size: CGFloat) -> NSImage? {
        guard let bundleID = spec.bundleID else { return nil }
        let key = "\(bundleID)@\(size)"
        if let cached = iconCache[key] { return cached }
        guard let url = appURL(for: spec) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        // Never resize the returned instance in place: AppKit hands back a
        // shared image for a path, and the size is a property of the object.
        guard let sized = icon.copy() as? NSImage else { return nil }
        sized.size = NSSize(width: size, height: size)
        sized.isTemplate = false
        iconCache[key] = sized
        return sized
    }

    static func appURL(for spec: ExtraItemSpec) -> URL? {
        guard let bundleID = spec.bundleID else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let url = running.bundleURL {
            return url
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func isRunning(_ spec: ExtraItemSpec) -> Bool {
        guard let bundleID = spec.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Open = what clicking the app's own icon or Dock tile does: launches a
    /// quit app, activates and reopens a running one.
    private func openApp(_ spec: ExtraItemSpec) {
        guard let url = Self.appURL(for: spec) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
    }

    /// A pickable app: running, user-facing (a regular app or a menu-bar
    /// agent the user installed), not Pelmet itself.
    struct PickableApp: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage
        var id: String { bundleID }
    }

    /// Running apps for the "+ App" picker, by name. Menu-bar-only agents
    /// (`.accessory`) are the whole point — that's where the icons Pelmet
    /// can't hide come from — and they must stay pickable AFTER the user
    /// turns the app's own icon off (the flow the card asks for), so the
    /// filter is "an app the user installed": regular apps, anything that
    /// owns a bar icon, or an agent living in /Applications. Background
    /// agents elsewhere (an updater, a sync helper) are noise.
    static func pickableRunningApps(barBundles: Set<String>) -> [PickableApp] {
        var seen: Set<String> = []
        var apps: [PickableApp] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != PelmetBundle.mainID,
                  !seen.contains(bundleID),
                  let url = app.bundleURL, isUserFacingApp(url),
                  app.activationPolicy == .regular
                    || barBundles.contains(bundleID)
                    || isInstalledApp(url),
                  let name = app.localizedName, !name.isEmpty,
                  let icon = app.icon?.copy() as? NSImage
            else { continue }
            seen.insert(bundleID)
            icon.size = NSSize(width: 16, height: 16)
            apps.append(PickableApp(bundleID: bundleID, name: name, icon: icon))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func isInstalledApp(_ url: URL) -> Bool {
        let path = url.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private static func isUserFacingApp(_ url: URL) -> Bool {
        guard url.pathExtension == "app" else { return false }
        let path = url.path
        // /System/Library holds the OS's own agents; /System/Applications
        // holds Music, Notes… which are fair launchers.
        if path.hasPrefix("/System/Library/") { return false }
        // Nested inside another app bundle = a helper, not an app.
        return !url.deletingLastPathComponent().path.contains(".app/")
    }

    /// The "+ App" picker as an AppKit menu: the running apps under one
    /// section label, then the open panel. Icons are set but macOS 27 b8 draws no NSMenuItem images
    /// at all (verified standalone, SF Symbols included).
    static func appPickerMenu(
        barBundles: Set<String>,
        excluding added: Set<String>,
        onPick: @escaping (PickableApp) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        let apps = pickableRunningApps(barBundles: barBundles).filter { !added.contains($0.bundleID) }
        func add(_ app: PickableApp) {
            let item = NSMenuItem(title: app.name, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.image = app.icon
            let action = MenuAction { onPick(app) }
            item.representedObject = action
            item.target = action
            menu.addItem(item)
        }
        if !apps.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Active applications")))
        }
        apps.forEach(add)
        if !apps.isEmpty { menu.addItem(.separator()) }
        let choose = NSMenuItem(title: String(localized: "Choose an app…"), action: #selector(MenuAction.fire), keyEquivalent: "")
        let chooseAction = MenuAction {
            if let app = pickInstalledApp() { onPick(app) }
        }
        choose.representedObject = chooseAction
        choose.target = chooseAction
        menu.addItem(choose)
        return menu
    }

    /// Closure target for NSMenuItems (retained via `representedObject`).
    private final class MenuAction: NSObject {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        @objc func fire() { body() }
    }

    /// Any installed app, via the open panel — for apps that aren't running
    /// right now (an "Always" launcher).
    static func pickInstalledApp() -> PickableApp? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = String(localized: "Choose an app to launch")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier
        else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return PickableApp(bundleID: bundleID, name: name, icon: icon)
    }

    /// SF Symbols has a real "airdrop" glyph on current systems; fall back to
    /// the radiating-waves look everywhere else.
    static let airdropSymbol: String = {
        NSImage(systemSymbolName: "airdrop", accessibilityDescription: nil) != nil
            ? "airdrop"
            : "dot.radiowaves.left.and.right"
    }()

    /// Reduce Motion: the animated set renders one still "live" frame.
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func animator(for spec: ExtraItemSpec, button: NSStatusBarButton) -> ExtraAnimator {
        if let animator = animators[spec.id] { return animator }
        let animator = ExtraAnimator(button: button)
        animators[spec.id] = animator
        return animator
    }

    /// Redraws one item's glyph for its current style and state; no
    /// placement side effects, safe from `sync`.
    private func refreshGlyph(_ item: NSStatusItem, spec: ExtraItemSpec) {
        switch spec.kind {
        case .mediaControls: updateMediaSymbol(item, spec: spec)
        case .cameraMicIndicator: updateCameraSymbol(item, spec: spec)
        case .airdrop: updateAirDropGlyph(item, spec: spec)
        case .timer: updateTimerGlyph(item, spec: spec)
        case .timeMachine: updateTimeMachineGlyph(item, spec: spec)
        case .focus: updateFocusGlyph(item, spec: spec)
        case .liveActivity: updateLiveActivityGlyph(item, spec: spec)
        case .shortcut, .appLauncher, .userSwitching, .shortcutsMenu, .siri, .quickNote: break
        }
    }

    /// The latest activity's app icon, in colour like a launcher's, when
    /// the Mac has the app; the platter when it doesn't (an iPhone app) or
    /// the log hasn't named it. More than one: how many, beside it.
    private func updateLiveActivityGlyph(_ item: NSStatusItem, spec: ExtraItemSpec) {
        guard let button = item.button else { return }
        let active = liveActivityStatus?.active ?? []
        let bundleID = active.last?.bundleID
        setGlyph(item, id: spec.id, key: "liveActivity:\(bundleID ?? "")") {
            bundleID.flatMap { Self.appIcon(for: ExtraItemSpec(kind: .liveActivity, bundleID: $0), size: 18) }
                ?? NSImage(systemSymbolName: Self.liveActivitySymbol, accessibilityDescription: spec.itemTitle)
        }
        if active.count > 1 {
            let size = NSFont.menuBarFont(ofSize: 0).pointSize
            button.attributedTitle = NSAttributedString(
                string: " \(active.count)",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]
            )
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    /// The watcher lives for the item, or for live mode alone while it can
    /// start: a log stream and an eight-hour replay are not spent on a Mac
    /// where Screen Recording keeps live mode from ever entering. The grant
    /// arriving (`screenRecordingChanged`) starts it, and while live mode
    /// waits on it the grant is re-read (`grantWait`), so one made with
    /// Settings and onboarding closed lands too.
    private func syncLiveActivityWatcher() {
        syncGrantWait()
        let hasItem = specs.values.contains { $0.kind == .liveActivity }
        let liveMode = appState?.settings.showLiveActivities == true && ScreenRecordingAccess.isGranted
        if hasItem || liveMode {
            if liveActivityStatus == nil {
                let status = LiveActivityStatus()
                status.onChange = { [weak self] in self?.liveActivityChanged() }
                liveActivityStatus = status
                status.start()
            }
        } else if let status = liveActivityStatus {
            status.stop()
            liveActivityStatus = nil
            // With the item off and live mode off or unable to start nothing
            // says an activity ended, so live mode is told here (it forgets
            // what it was told).
            appState?.liveActivitiesChanged(running: false, count: 0)
        }
        // The item's edge tracking starts over when it goes, watcher or not.
        if !hasItem { lastLiveActivityActive = false }
    }

    /// The grant flips `AppState.screenRecordingGranted`, whose
    /// `screenRecordingChanged` comes back here and ends the wait.
    private func syncGrantWait() {
        let waits = appState?.settings.showLiveActivities == true && appState?.screenRecordingGranted == false
        if waits, grantWait == nil {
            PelmetLog.log("live activities: live mode waits for Screen Recording, re-reading the grant")
            grantWait = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: AppTiming.screenRecordingPoll)
                    self?.appState?.refreshScreenRecording()
                }
            }
        } else if !waits, let wait = grantWait {
            wait.cancel()
            grantWait = nil
        }
    }

    /// Screen Recording was granted or lost (`AppState.refreshScreenRecording`).
    func screenRecordingChanged() {
        syncLiveActivityWatcher()
    }

    private func liveActivityChanged() {
        appState?.liveActivitiesChanged(running: !(liveActivityStatus?.active.isEmpty ?? true), count: liveActivityStatus?.active.count ?? 0)
        guard let spec = specs.values.first(where: { $0.kind == .liveActivity }),
              let item = items[spec.id] else { return }
        let active = !(liveActivityStatus?.active.isEmpty ?? true)
        if active != lastLiveActivityActive {
            applyCurrent()  // the visibility edge
        } else {
            updateLiveActivityGlyph(item, spec: spec)  // another app, another count
        }
    }

    /// The active mode's own symbol (macOS names it in the log line); an
    /// outlined moon while off, the way Apple's always-shown item rests.
    private func updateFocusGlyph(_ item: NSStatusItem, spec: ExtraItemSpec) {
        let symbol = focusStatus?.active?.symbol ?? "moon"
        setGlyph(item, id: spec.id, key: "focus:\(symbol)") {
            NSImage(systemSymbolName: symbol, accessibilityDescription: spec.itemTitle)
                ?? NSImage(systemSymbolName: "moon.fill", accessibilityDescription: spec.itemTitle)
        }
    }

    private func focusChanged() {
        guard let spec = specs.values.first(where: { $0.kind == .focus }),
              let item = items[spec.id] else { return }
        let active = focusStatus?.active != nil
        if active != lastFocusActive {
            applyCurrent()  // the visibility edge
        } else {
            updateFocusGlyph(item, spec: spec)  // one mode to another
        }
    }

    /// The countdown beside the glyph while a timer runs; glyph only when
    /// idle. Monospaced digits so the width holds from second to second.
    private func updateTimerGlyph(_ item: NSStatusItem, spec: ExtraItemSpec) {
        guard let button = item.button else { return }
        let text = pelmetTimer?.display
        let done = pelmetTimer?.shown == .done
        setGlyph(item, id: spec.id, key: "timer:\(done)") {
            NSImage(systemSymbolName: done ? "bell.fill" : "timer", accessibilityDescription: spec.itemTitle)
        }
        if let text {
            let size = NSFont.menuBarFont(ofSize: 0).pointSize
            button.attributedTitle = NSAttributedString(
                string: " " + text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]
            )
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    private func timerChanged() {
        guard let spec = specs.values.first(where: { $0.kind == .timer }),
              let item = items[spec.id] else { return }
        let active = pelmetTimer?.isActive ?? false
        if active != lastTimerActive {
            applyCurrent()  // the visibility override edge
        } else {
            updateTimerGlyph(item, spec: spec)
        }
    }

    /// Static: play when idle (click plays), pause while audio is running
    /// (click pauses) — the button shows the action a click will take.
    /// Animated: the bars wave while playing and settle to a resting stack
    /// when paused, Sconce's tell.
    private func updateMediaSymbol(_ item: NSStatusItem, spec: ExtraItemSpec) {
        guard let button = item.button else { return }
        if spec.resolvedStyle == .animated {
            let animator = animator(for: spec, button: button)
            animator.targetLevel = mediaPlaying ? 1 : 0
            if Self.reduceMotion {
                animator.stop()
                button.image = ExtraGlyph.mediaBars(t: 0, level: mediaPlaying ? 1 : 0, animated: false)
            } else {
                animator.run(tag: "bars", fps: ExtraGlyph.barsFPS) { t, level in
                    ExtraGlyph.mediaBars(t: t, level: level, animated: true)
                }
            }
            return
        }
        animators[spec.id]?.stop()
        let playing = mediaPlaying
        setGlyph(item, id: spec.id, key: "media:\(playing)") {
            NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: spec.itemTitle)
        }
    }

    /// The drawn AirDrop mark.
    private func updateAirDropGlyph(_ item: NSStatusItem, spec: ExtraItemSpec) {
        setGlyph(item, id: spec.id, key: "airdrop") { ExtraGlyph.airdrop }
    }

    /// Apple's own faces: the clock while idle, the arrows while a backup
    /// runs, the exclamation after a failed one. Same image object each
    /// time so an unchanged state costs no replicant redraw.
    private func updateTimeMachineGlyph(_ item: NSStatusItem, spec: ExtraItemSpec) {
        let status = timeMachine?.status ?? .init()
        let image = status.running ? ExtraGlyph.timeMachineBackingUp
            : status.failed ? ExtraGlyph.timeMachineFailed
            : ExtraGlyph.timeMachineIdle
        if item.button?.image !== image { item.button?.image = image }
    }

    private func timeMachineChanged() {
        let running = timeMachine?.status.running ?? false
        if running != lastBackupRunning,
           specs.values.contains(where: { $0.kind == .timeMachine && $0.comesOutWhileActive }) {
            applyCurrent()  // the visibility edge
            return
        }
        for (id, item) in items {
            guard let spec = specs[id], spec.kind == .timeMachine else { continue }
            updateTimeMachineGlyph(item, spec: spec)
        }
    }

    private func updateCameraSymbol(_ item: NSStatusItem, spec: ExtraItemSpec) {
        let monitor = cameraMicMonitor
        let camera = monitor?.cameraActive ?? false
        let mic = monitor?.micActive ?? false
        // SharePlay with no call: the pill wears its glyph, even with the
        // camera up (FaceTime's open window keeps it running); the colour
        // stays the privacy signal, plain when nothing records.
        let sharePlay = sharePlayStatus?.isLive ?? false
        let symbol = sharePlay ? "shareplay" : (camera ? "video.fill" : (mic ? "mic.fill" : "video.fill"))
        let key = "camera:\(symbol):\(camera):\(mic)"
        guard glyphKeys[spec.id] != key || item.button?.image == nil else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: String(localized: "Camera & Mic"))
        if camera || mic {
            image?.isTemplate = false
            item.button?.contentTintColor = camera ? .systemGreen : .systemOrange
        } else {
            item.button?.contentTintColor = nil
        }
        item.button?.image = image
        glyphKeys[spec.id] = key
    }

    // MARK: Actions

    /// The item's own spot (global, top-left origin): the Apple item to
    /// press is the copy on this item's display.
    private static func barPoint(of sender: NSStatusBarButton) -> CGPoint {
        let frame = sender.window?.frame ?? .zero
        return CGPoint(x: frame.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.midY)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard
            let statusItem = items.first(where: { $0.value.button === sender }),
            let spec = specs[statusItem.key]
        else { return }
        perform(spec, on: statusItem, rightClick: NSApp.currentEvent?.type == .rightMouseUp)
    }

    /// What a press from outside the bar (the command bar, an item's own
    /// shortcut) needs before `activate` can run the extra's action.
    enum PressNeed {
        /// It runs wherever the item is: a media key, a launch, a toggle.
        case nothing
        /// It pops a menu from the item's own button, so the item has to be
        /// on the bar for the menu to anchor.
        case onBar
        /// It opens Apple's pill at the item's spot, and only the camera
        /// being live puts the item there: no section reveal helps.
        case live
    }

    /// The extra that has this key; nil for a separator, the chevron, or
    /// anything that is not one of the extras.
    private func entry(for key: ItemID) -> (key: UUID, value: NSStatusItem)? {
        items.first { entry in
            specs[entry.key].map { Self.itemID(for: $0).sectionKey == key.sectionKey } ?? false
        }
    }

    /// Which of `perform`'s presses open a menu from the button, and which
    /// need the camera live. Keep it in step with `perform`.
    func pressNeed(itemKey key: ItemID, rightClick: Bool) -> PressNeed? {
        guard let entry = entry(for: key), let spec = specs[entry.key] else { return nil }
        switch spec.kind {
        case .mediaControls, .siri, .focus:
            return rightClick ? .onBar : .nothing
        case .cameraMicIndicator:
            return rightClick ? .nothing : .live
        case .airdrop, .shortcut, .quickNote, .liveActivity:
            return .nothing
        case .timer:
            guard let timer = pelmetTimer, !rightClick else { return .onBar }
            return timer.state == .done || timer.showsClock ? .nothing : .onBar
        case .userSwitching, .shortcutsMenu, .timeMachine:
            return .onBar
        case .appLauncher:
            return rightClick && Self.isRunning(spec) && spec.bundleID != nil ? .onBar : .nothing
        }
    }

    /// The action the item's button runs on a click, run directly: no
    /// click is made on the item. A menu pops from the item when it is on
    /// the bar, else where the pointer is. False when no extra has this key.
    @discardableResult
    func activate(itemKey key: ItemID, rightClick: Bool = false) -> Bool {
        guard let entry = entry(for: key), let spec = specs[entry.key] else { return false }
        perform(spec, on: entry, rightClick: rightClick)
        return true
    }

    private func perform(_ spec: ExtraItemSpec, on statusItem: (key: UUID, value: NSStatusItem), rightClick: Bool) {
        switch spec.kind {
        case .mediaControls:
            if rightClick {
                let menu = NSMenu()
                let previous = NSMenuItem(title: String(localized: "Previous Track"), action: #selector(previousTrack), keyEquivalent: "")
                let next = NSMenuItem(title: String(localized: "Next Track"), action: #selector(nextTrack), keyEquivalent: "")
                for menuItem in [previous, next] { menuItem.target = self }
                menu.items = [previous, next]
                popUp(menu, on: statusItem.value)
            } else {
                MediaKey.playPause.send()
                mediaPlaying.toggle()
                updateMediaSymbol(statusItem.value, spec: spec)
            }
        case .cameraMicIndicator:
            // Apple's own pill (video effects, mic mode, Stop Sharing), which
            // no assertion lets on the bar (#68). A right-click, or no pill
            // to open, goes to Privacy settings for a quick audit.
            let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
            guard !rightClick else { NSWorkspace.shared.open(privacy); return }
            guard !AudioVideoPill.clickClosedPanel(), let appState, let button = statusItem.value.button else { return }
            let point = Self.barPoint(of: button)
            // A SharePlay session with no call: Apple's SharePlay icon first.
            let ids = (sharePlayStatus?.isLive ?? false)
                ? [AudioVideoPill.sharePlayIdentifier, AudioVideoPill.identifier]
                : [AudioVideoPill.identifier]
            Task { @MainActor in
                if !(await appState.openAudioVideoPill(near: point, identifiers: ids)) { NSWorkspace.shared.open(privacy) }
            }
        case .airdrop:
            openAirDrop()
        case .quickNote:
            QuickNote.open()
        case .liveActivity:
            // The real pills, live and clickable: only the bar with no
            // assertion held shows them (#106).
            appState?.liftHideForLiveActivities()
        case .shortcut:
            if let name = spec.shortcutName {
                runShortcut(named: name)
            }
        case .timer:
            guard let timer = pelmetTimer else { return }
            if timer.showsClock, !rightClick {
                // The Clock app pauses, cancels and dismisses its own timer.
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Clock.app"), configuration: .init())
            } else if timer.state == .done, !rightClick {
                timer.dismiss()
            } else {
                popUp(timerMenu(timer), on: statusItem.value)
            }
        case .userSwitching:
            popUp(usersMenu(), on: statusItem.value)
        case .shortcutsMenu:
            // Read fresh each open (~15ms a CLI call), off the main thread.
            Task { @MainActor [weak self] in
                let library = await Task.detached { Self.shortcutsLibrary() }.value
                guard let self else { return }
                popUp(shortcutsMenu(library), on: statusItem.value)
            }
        case .timeMachine:
            // Fresh for the next open; this one shows what the poll last saw.
            timeMachine?.refresh()
            popUp(timeMachineMenu(), on: statusItem.value)
        case .siri:
            if rightClick {
                let menu = NSMenu()
                let talk = NSMenuItem(title: String(localized: "Talk to Siri"), action: #selector(talkToSiri), keyEquivalent: "")
                talk.target = self
                let settings = NSMenuItem(title: String(localized: "Siri Settings…"), action: #selector(siriSettings), keyEquivalent: "")
                settings.target = self
                menu.items = [talk, .separator(), settings]
                popUp(menu, on: statusItem.value)
            } else {
                Siri.tap()
            }
        case .focus:
            if rightClick {
                let menu = NSMenu()
                let settings = NSMenuItem(title: String(localized: "Focus Settings…"), action: #selector(focusSettings), keyEquivalent: "")
                settings.target = self
                menu.items = [settings]
                popUp(menu, on: statusItem.value)
            } else {
                ControlCenterFocus.toggle()
            }
        case .appLauncher:
            if rightClick, Self.isRunning(spec), let bundleID = spec.bundleID {
                let menu = NSMenu()
                let quit = NSMenuItem(
                    title: String(localized: "Quit \(spec.appName ?? bundleID)"),
                    action: #selector(quitApp(_:)),
                    keyEquivalent: ""
                )
                quit.target = self
                quit.representedObject = bundleID
                menu.items = [quit]
                popUp(menu, on: statusItem.value)
            } else {
                openApp(spec)
            }
        }
    }

    private func popUp(_ menu: NSMenu, on item: NSStatusItem) {
        // An item out of the bar (a press from the command bar while its
        // section stays concealed) has no spot to anchor to: the menu pops
        // where the pointer is.
        guard items.first(where: { $0.value === item }).map({ lastVisible[$0.key] == true }) ?? false else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func previousTrack() { MediaKey.previous.send() }
    @objc private func nextTrack() { MediaKey.next.send() }

    // MARK: Timer menu

    private func timerMenu(_ timer: PelmetTimer) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, tag: Int = 0) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.tag = tag
            menu.addItem(entry)
        }
        switch timer.state {
        case .idle:
            for duration in PelmetTimer.presets {
                add(PelmetTimer.label(for: duration), #selector(startTimer(_:)), tag: Int(duration))
            }
            menu.addItem(.separator())
            add(String(localized: "Custom…"), #selector(customTimer))
        case .running, .paused:
            if let display = timer.display {
                let header = NSMenuItem(title: String(localized: "\(display) left"), action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                menu.addItem(.separator())
            }
            if case .running = timer.state {
                add(String(localized: "Pause"), #selector(pauseTimer))
            } else {
                add(String(localized: "Resume"), #selector(resumeTimer))
            }
            add(String(localized: "Add a minute"), #selector(addTimerMinute))
            menu.addItem(.separator())
            add(String(localized: "Cancel timer"), #selector(cancelTimer))
        case .done:
            add(String(localized: "Dismiss"), #selector(dismissTimer))
        }
        return menu
    }

    @objc private func startTimer(_ sender: NSMenuItem) {
        pelmetTimer?.start(TimeInterval(sender.tag))
    }

    @objc private func customTimer() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Timer")
        alert.informativeText = String(localized: "Minutes")
        alert.addButton(withTitle: String(localized: "Start"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.placeholderString = "10"
        field.alignment = .center
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let minutes = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard minutes > 0 else { return }
        pelmetTimer?.start(minutes * 60)
    }

    @objc private func pauseTimer() { pelmetTimer?.pause() }
    @objc private func resumeTimer() { pelmetTimer?.resume() }
    @objc private func addTimerMinute() { pelmetTimer?.addMinute() }
    @objc private func cancelTimer() { pelmetTimer?.cancel() }
    @objc private func dismissTimer() { pelmetTimer?.dismiss() }

    // MARK: Users menu

    private func usersMenu() -> NSMenu {
        let menu = NSMenu()
        let me = NSMenuItem(title: UserSwitching.current.fullName, action: nil, keyEquivalent: "")
        me.isEnabled = false
        menu.addItem(me)
        let others = UserSwitching.otherAccounts()
        if !others.isEmpty {
            menu.addItem(.separator())
            for account in others {
                let entry = NSMenuItem(title: account.fullName, action: #selector(switchUser(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = account.name
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        for (title, action) in [
            (String(localized: "Login Window…"), #selector(loginWindow)),
            (String(localized: "Lock Screen"), #selector(lockScreen)),
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Users & Groups Settings…"), action: #selector(usersSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    @objc private func switchUser(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let account = UserSwitching.otherAccounts().first(where: { $0.name == name }) else { return }
        UserSwitching.switchTo(account)
    }

    @objc private func loginWindow() { UserSwitching.switchToLoginWindow() }
    @objc private func lockScreen() { UserSwitching.lockScreen() }
    @objc private func usersSettings() { UserSwitching.openUsersSettings() }

    /// Unfiled shortcuts first, in library order, then each folder as a
    /// submenu. Entries run by identifier: two shortcuts can share a name.
    private func shortcutsMenu(_ library: ShortcutsLibrary) -> NSMenu {
        let menu = NSMenu()
        func entry(_ shortcut: ShortcutsLibrary.Entry) -> NSMenuItem {
            let item = NSMenuItem(title: shortcut.name, action: #selector(runMenuShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shortcut.id
            return item
        }
        if library.isEmpty {
            let none = NSMenuItem(title: String(localized: "No shortcuts in your library"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for shortcut in library.unfiled { menu.addItem(entry(shortcut)) }
        if !library.unfiled.isEmpty, !library.folders.isEmpty { menu.addItem(.separator()) }
        for folder in library.folders {
            let sub = NSMenu()
            for shortcut in folder.shortcuts { sub.addItem(entry(shortcut)) }
            let item = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: String(localized: "Open Shortcuts"), action: #selector(openShortcutsApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        return menu
    }

    @objc private func runMenuShortcut(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        runShortcut(named: id)
    }

    @objc private func openShortcutsApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: Time Machine menu

    /// Apple's menu, line for line: the state on top, then the verbs.
    private func timeMachineMenu() -> NSMenu {
        let menu = NSMenu()
        func label(_ title: String) {
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        func verb(_ title: String, _ action: Selector) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        let status = timeMachine?.status ?? .init()
        if status.running {
            if status.stopping {
                label(String(localized: "Stopping Backup…"))
            } else if let percent = status.percent {
                label(String(localized: "Backing Up: \(Int((percent * 100).rounded()))%"))
            } else if status.phase == "Finishing" || status.phase?.hasPrefix("Thinning") == true {
                label(String(localized: "Finishing Backup…"))
            } else {
                label(String(localized: "Preparing Backup…"))
            }
        } else if let destination = TimeMachineBackup.destination() {
            if let latest = destination.latestBackup {
                label(String(localized: "Latest Backup to “\(destination.name)”"))
                label(Self.backupDateFormatter.string(from: latest))
            } else {
                label(String(localized: "Waiting to Complete First Backup"))
            }
            if destination.failed {
                label(String(localized: "Backup Failed…"))
            }
        } else {
            label(String(localized: "No Backup Disk Selected"))
        }
        menu.addItem(.separator())
        if status.running, !status.stopping {
            verb(String(localized: "Skip This Backup"), #selector(skipBackup))
        } else {
            verb(String(localized: "Back Up Now"), #selector(backUpNow))
        }
        menu.addItem(.separator())
        verb(String(localized: "Browse Time Machine Backups"), #selector(browseBackups))
        menu.addItem(.separator())
        verb(String(localized: "Open Time Machine Settings…"), #selector(timeMachineSettings))
        return menu
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    @objc private func backUpNow() { timeMachine?.backUpNow() }
    @objc private func skipBackup() { timeMachine?.skipBackup() }
    @objc private func browseBackups() { TimeMachineBackup.browseBackups() }
    @objc private func timeMachineSettings() { TimeMachineBackup.openSettings() }
    @objc private func talkToSiri() { Siri.talk() }
    @objc private func siriSettings() { Siri.openSettings() }
    @objc private func focusSettings() { ControlCenterFocus.openSettings() }

    private func openAirDrop() {
        // Finder's AirDrop view via its keyboard shortcut (⇧⌘R) — the only
        // stable public entry point. The chord is posted globally, so ONLY
        // post it once Finder actually owns the keyboard: on a slow
        // activation the chord would land in whatever is frontmost instead
        // (⇧⌘R is Reply-All in Mail, Reader in Safari…). Retry briefly, then
        // give up silently.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        postAirDropChordWhenFinderFrontmost(attempt: 0)
    }

    private func postAirDropChordWhenFinderFrontmost(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
                if attempt < 4 {
                    self.postAirDropChordWhenFinderFrontmost(attempt: attempt + 1)
                }
                return
            }
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 15 /* R */, keyDown: down)
                event?.flags = [.maskCommand, .maskShift]
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private func runShortcut(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        try? process.run()
    }

    /// Names from the user's Shortcuts library (for the picker).
    nonisolated static func availableShortcuts() -> [String] {
        shortcutsCLI(["list"])
    }

    /// The library as the Shortcuts CLI sees it: real folders only (the
    /// Share Sheet / Menu Bar collections are not folders to it).
    nonisolated static func shortcutsLibrary() -> ShortcutsLibrary {
        func entries(in folder: String) -> [ShortcutsLibrary.Entry] {
            shortcutsCLI(["list", "--folder-name", folder, "--show-identifiers"]).compactMap(ShortcutsLibrary.Entry.init(line:))
        }
        let folders = shortcutsCLI(["list", "--folders"])
            .filter { $0 != "none" }
            .map { (name: $0, shortcuts: entries(in: $0)) }
            .filter { !$0.shortcuts.isEmpty }
        return ShortcutsLibrary(unfiled: entries(in: "none"), folders: folders)
    }

    private nonisolated static func shortcutsCLI(_ arguments: [String]) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        // Read BEFORE waiting: with output past the 64KB pipe buffer, the
        // child blocks on write and waitUntilExit never returns.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

// MARK: - Shortcuts library

/// What the Shortcuts menu lists, read through `/usr/bin/shortcuts`.
nonisolated struct ShortcutsLibrary: Sendable {
    struct Entry: Sendable {
        let name: String
        let id: String

        /// One `list --show-identifiers` line: `Name (UUID)`.
        init?(line: String) {
            guard line.hasSuffix(")"), let open = line.lastIndex(of: "(") else { return nil }
            let id = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
            guard UUID(uuidString: id) != nil else { return nil }
            self.name = String(line[..<open]).trimmingCharacters(in: .whitespaces)
            self.id = id
        }
    }

    var unfiled: [Entry]
    var folders: [(name: String, shortcuts: [Entry])]

    var isEmpty: Bool { unfiled.isEmpty && folders.isEmpty }
}

// MARK: - Camera / mic activity

/// "Is any camera/mic in use" via public CoreMediaIO / CoreAudio properties
/// (the OverSight approach) — EVENT-DRIVEN: `DeviceIsRunningSomewhere`
/// property listeners per device (plus device-list listeners for hot-plug)
/// re-poll on change, and a slow 30s fallback timer covers the media-linger
/// expiry and any listener the OS fails to deliver. The original 2s poll was
/// Pelmet's only steady idle wakeup.
final class CameraMicMonitor {
    private(set) var cameraActive = false
    private(set) var micActive = false
    /// Any audio OUTPUT device running — the "something is playing" signal.
    private(set) var audioOutputActive = false
    private(set) var lastAudioActiveAt: Date = .distantPast
    private var timer: Timer?
    /// Output running this long counts as playing. A system sound keeps the
    /// device running near 3s (a Tink, 2.8s measured 2026-10-12), so each
    /// screenshot shutter brought the media item up for the whole linger.
    static let sustainedAudio: TimeInterval = 5
    private var audioRunningSince: Date?
    /// Runs the wait out: no device event says it is over.
    private var sustainedTimer: Timer?
    private let onChange: () -> Void
    // nonisolated(unsafe): mutated only on the main actor (install/remove),
    // but deinit must read them to unhook the HAL — Swift 6 bars isolated
    // property access from deinitializers.
    private nonisolated(unsafe) var audioListenerDevices: [AudioObjectID] = []
    private nonisolated(unsafe) var cmioListenerDevices: [CMIOObjectID] = []
    // C-function-pointer listeners, NOT the *ListenerBlock variants: the HAL
    // matches removals by block identity, and Swift re-bridges a closure to a
    // fresh block object on every call — so block removals never matched,
    // listeners accumulated across reinstalls, and each device event fanned
    // out into a main-thread reinstall storm (the 2026-08-21 beachball).
    // Function pointer + clientData compare reliably. Callbacks arrive on a
    // HAL thread; hop to main before touching state.
    private nonisolated static let audioListenerProc: AudioObjectPropertyListenerProc = { _, count, addresses, clientData in
        guard let clientData else { return noErr }
        let monitor = Unmanaged<CameraMicMonitor>.fromOpaque(clientData).takeUnretainedValue()
        let listChanged = UnsafeBufferPointer(start: addresses, count: Int(count))
            .contains { $0.mSelector == kAudioHardwarePropertyDevices }
        DispatchQueue.main.async {
            listChanged ? monitor.deviceListChanged() : monitor.poll()
        }
        return noErr
    }
    private nonisolated static let cmioListenerProc: CMIOObjectPropertyListenerProc = { _, count, addresses, clientData in
        guard let clientData else { return noErr }
        let monitor = Unmanaged<CameraMicMonitor>.fromOpaque(clientData).takeUnretainedValue()
        let listChanged = UnsafeBufferPointer(start: addresses, count: Int(count))
            .contains { $0.mSelector == CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices) }
        DispatchQueue.main.async {
            listChanged ? monitor.deviceListChanged() : monitor.poll()
        }
        return noErr
    }

    var isActive: Bool { cameraActive || micActive }

    /// Playing now, or within the linger window — so pausing music doesn't
    /// swallow the resume button. (Apple keeps Now Playing for the paused
    /// session via private API; the linger is the honest approximation.)
    var mediaRelevant: Bool {
        audioSustained || Date().timeIntervalSince(lastAudioActiveAt) < 300
    }

    /// Output running long enough to be playback, not a UI sound.
    private var audioSustained: Bool {
        audioRunningSince.map { Date().timeIntervalSince($0) >= Self.sustainedAudio } ?? false
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        // Fallback only: catches the media-linger window expiring (a pure
        // wall-clock transition no listener fires for) and any missed
        // listener delivery. Generous tolerance = coalesced wakeups.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 5
        installListeners()
        poll()
    }

    // stop() is the normal teardown (ExtrasManager removes the entry);
    // deinit is the guard rail — a release without stop() would leave the
    // HAL dispatching to a dangling clientData pointer. The timer is left
    // to its weak-self no-op (invalidating cross-thread from deinit is
    // unsafe); the HAL pointer is the real hazard.
    deinit {
        Self.removeCListeners(
            selfPtr: Unmanaged.passUnretained(self).toOpaque(),
            audioDevices: audioListenerDevices,
            cmioDevices: cmioListenerDevices
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sustainedTimer?.invalidate()
        sustainedTimer = nil
        removeListeners()
    }

    /// Device topology changed (hot-plug) — re-install the per-device
    /// listeners. Running-state changes skip this and go straight to poll().
    private func deviceListChanged() {
        removeListeners()
        installListeners()
        poll()
    }

    private func installListeners() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // System object: device list changes (hot-plug).
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, Self.audioListenerProc, selfPtr
        )
        for deviceID in Self.allAudioDeviceIDs() {
            if AudioObjectAddPropertyListener(deviceID, &runningAddress, Self.audioListenerProc, selfPtr) == noErr {
                audioListenerDevices.append(deviceID)
            }
        }

        var cmioRunning = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var cmioDevices = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectAddPropertyListener(
            CMIOObjectID(kCMIOObjectSystemObject), &cmioDevices, Self.cmioListenerProc, selfPtr
        )
        for deviceID in Self.allCMIODeviceIDs() {
            if CMIOObjectAddPropertyListener(deviceID, &cmioRunning, Self.cmioListenerProc, selfPtr) == noErr {
                cmioListenerDevices.append(deviceID)
            }
        }
    }

    private func removeListeners() {
        Self.removeCListeners(
            selfPtr: Unmanaged.passUnretained(self).toOpaque(),
            audioDevices: audioListenerDevices,
            cmioDevices: cmioListenerDevices
        )
        audioListenerDevices = []
        cmioListenerDevices = []
    }

    /// Static + nonisolated so deinit can reach it: removal matches by
    /// (proc, clientData) identity, so it needs only the pointer and the
    /// device lists — not isolated state access.
    private nonisolated static func removeCListeners(
        selfPtr: UnsafeMutableRawPointer,
        audioDevices: [AudioObjectID],
        cmioDevices cmioDeviceList: [CMIOObjectID]
    ) {
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, Self.audioListenerProc, selfPtr
        )
        for deviceID in audioDevices {
            AudioObjectRemovePropertyListener(deviceID, &runningAddress, Self.audioListenerProc, selfPtr)
        }

        var cmioRunning = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var cmioDevices = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectRemovePropertyListener(
            CMIOObjectID(kCMIOObjectSystemObject), &cmioDevices, Self.cmioListenerProc, selfPtr
        )
        for deviceID in cmioDeviceList {
            CMIOObjectRemovePropertyListener(deviceID, &cmioRunning, Self.cmioListenerProc, selfPtr)
        }
    }

    private static func allAudioDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }
        var deviceIDs = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }
        return deviceIDs
    }

    private static func allCMIODeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }
        var deviceIDs = [CMIOObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &dataUsed, &deviceIDs
        ) == noErr else { return [] }
        return deviceIDs
    }

    private func poll() {
        let camera = Self.anyCameraRunning()
        let mic = Self.anyMicRunning()
        let wasSustained = audioSustained
        let audio = Self.anyOutputRunning()
        if audio, audioRunningSince == nil {
            audioRunningSince = Date()
            sustainedTimer?.invalidate()
            sustainedTimer = Timer.scheduledTimer(withTimeInterval: Self.sustainedAudio + 0.1, repeats: false) { [weak self] _ in
                self?.poll()
            }
        } else if !audio {
            audioRunningSince = nil
            sustainedTimer?.invalidate()
            sustainedTimer = nil
        }
        // The linger runs from the moment playback stopped.
        if audioSustained || wasSustained { lastAudioActiveAt = Date() }
        let relevantNow = mediaRelevant
        if camera != cameraActive || mic != micActive || audio != audioOutputActive
            || relevantNow != lastMediaRelevant {
            cameraActive = camera
            micActive = mic
            audioOutputActive = audio
            lastMediaRelevant = relevantNow
            onChange()
        }
    }

    private var lastMediaRelevant = true

    private static func anyOutputRunning() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return false }
        for deviceID in deviceIDs {
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &size, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }

    private static func anyCameraRunning() -> Bool {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var deviceIDs = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, dataSize, &dataUsed, &deviceIDs
        ) == noErr else { return false }

        var runningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        for deviceID in deviceIDs {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(deviceID, &runningAddress, 0, nil, size, &size, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }

    private static func anyMicRunning() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return false }

        for deviceID in deviceIDs {
            // Input side only.
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }

            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &size, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }
}
