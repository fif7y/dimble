// AppState.swift
// Root composition: owns the engine, the rehide state machine, settings, and
// the status item. All UI-facing state is @Observable.

import AppKit
import PelmetCore
import PelmetEngine
import SwiftUI

/// Where a reveal was decided (`AppState.revealDecision(for:)`): the display
/// and what it shows the hidden icons in.
struct RevealDecision: Equatable {
    var display: CGDirectDisplayID?
    var uuid: String?
    var target: RevealTarget
    /// Went where the display's choice said: false for the reasons that
    /// need the bar whatever it says (`RevealRouting.needsBar`).
    var followsChoice = true
    /// The other displays that hide icons keep their bars concealed: every
    /// reveal but the ones that need every bar (Apply, the editor).
    var holdsOthers = true
}

@Observable
final class AppState {
    let engine = AgentBarEngine()
    var settings = SettingsStore.load() {
        // Every path that moves an icon between sections (the editor drop,
        // adoption, Discard, the command bar) assigns the roster through
        // here, and not all of them go through `settingsChanged`.
        didSet { grouper.noteRoster(settings.sectionModel.roster) }
    }
    private(set) var snapshot: EngineSnapshot?
    private(set) var accessibilityGranted = AccessibilityAccess.isGranted
    /// Optional grant behind the hide/reveal covers; re-read while the
    /// General tab is up (no watcher — nothing in the app depends on it).
    private(set) var screenRecordingGranted = ScreenRecordingAccess.isGranted
    private(set) var engineCanHide = true
    /// Settings window tab. Owned here (not view @State) so every window
    /// open can reset it to General — reopening straight onto the Menu Bar
    /// tab fired its full-reveal preview unprompted.
    var settingsTab: SettingsTab = .general {
        didSet {
            // Apply's "N not moved" belongs to the editor it came from (#60).
            if oldValue == .menuBar, settingsTab != .menuBar { applyReport = nil }
        }
    }
    /// While the settings window is open, auto-rehide is fully suppressed —
    /// the user is mid-workflow between the editor and the bar, and nothing
    /// should collapse under them. Closing the window re-conceals.
    /// Only the layout editor holds the bar open: it previews the full bar
    /// and drags there must stay in sync with it. On any other tab (or with
    /// the window closed) hover-rehide behaves normally (Gab, 2026-09-02).
    /// Sets core: the editor no longer shows the bar, so it holds it only
    /// for the span of an Apply pass.
    var editorHoldsBar: Bool {
        settingsWindowVisible && settingsTab == .menuBar && applying
    }

    /// The shortcut in settings could not be registered (another app holds
    /// it) — the General row says so beside the recorder.
    private(set) var hotkeyConflict = false
    private(set) var settingsHotkeyConflict = false
    private(set) var alwaysHiddenHotkeyConflict = false
    private(set) var notificationCenterHotkeyConflict = false
    private(set) var searchHotkeyConflict = false
    /// One-shot: the setting row (`SettingsIndex` id) Settings should scroll
    /// to and mark. Set by `openSettings(tab:row:)`, cleared by the view.
    var settingsFocusRow: String?
    /// Icons "Add a Shortcut…" sent to Settings › Search (section keys).
    /// The pane's list of icons without an alias yet is its own state, so it
    /// takes these when they arrive and clears them.
    var pendingAliasItems: [String] = []
    /// Bumped when the command bar saves or resets its history, so the
    /// Settings row that offers the reset knows whether there is any.
    var searchHistoryRevision = 0

    var settingsWindowVisible = false {
        didSet {
            guard oldValue != settingsWindowVisible else { return }
            if !settingsWindowVisible {
                applyReport = nil
                applyPointerDisplayPolicyAfterDismissal()
            }
        }
    }

    /// Per-display behavior is "the display the pointer is on wins" — this is
    /// that display's setting. Every path that could conceal the bar must
    /// consult it; reveal-side crossings live in MenuBarBandMonitor.
    var pointerDisplayBehavior: DisplayBehavior {
        settings.behavior(forDisplayUUID: NSScreen.underPointer?.displayUUIDString)
    }

    @ObservationIgnored lazy var transitions = TransitionCoordinator(appState: self, engine: engine)
    /// Live mode: the Live Activities pill mirrored beside the « while the
    /// bar reads concealed (the "Show Live Activities" setting).
    @ObservationIgnored lazy var liveMirror = LiveMirror(appState: self)
    @ObservationIgnored private lazy var barPresenter = BarPresenter(transitions: transitions)
    /// The hidden icons as tiles under the chevron (docs/PANEL-PLAN.md §5).
    @ObservationIgnored lazy var panelPresenter = PanelPresenter(appState: self)
    /// Who drew the reveal that is up, so the conceal goes to the same one.
    /// nil at rest.
    @ObservationIgnored private var revealPresenter: (any RevealPresenter)?
    /// The panel is drawing the reveal: the machine says revealed, the bar
    /// itself stays concealed.
    var panelShowsReveal: Bool { revealPresenter === panelPresenter }
    /// The display the reveal that is up was decided on, and where it shows
    /// the hidden icons there (`.menuBar` when the bar drew it). Kept until
    /// it conceals: the pointer moving to another display doesn't re-route
    /// it. nil at rest.
    @ObservationIgnored private(set) var revealDecision: RevealDecision?
    /// Per revealed section, its items left to right as the last reveal
    /// settle read them off the bar. Memory only: the panel's tile order
    /// (`PanelModel.build(drawnOrder:)`), since the bar's order is read and
    /// never stored.
    @ObservationIgnored private(set) var lastDrawnOrder: [PelmetCore.Section: [ItemID]] = [:]
    /// Opens an item's menu in place, hidden or not (see ItemPress).
    @ObservationIgnored private lazy var press = ItemPress(appState: self)
    /// The keyboard way into the bar (see CommandBarController).
    @ObservationIgnored lazy var commandBar = CommandBarController(appState: self)
    /// Settings › Search's working demo; active while that pane shows.
    @ObservationIgnored lazy var searchDemo = CommandBarController(appState: self, embedded: true)
    /// Keeps icons on their section's side of the chevron (see SectionGrouper).
    @ObservationIgnored private(set) lazy var grouper = SectionGrouper(appState: self)
    private var rehide = RehideStateMachine()
    /// Icons Show in Menu Bar brought out on their own, their sections still
    /// concealed. The rehide machine owns when they go back: `.revealed` with
    /// no sections is this state, and every conceal takes the set back
    /// (`takeItemsInBar`). While it is not empty a hold sits on the idle
    /// picture (`TransitionCoordinator.pressBegan`), as for a press.
    @ObservationIgnored private(set) var itemsInBar: Set<ItemID> = []
    private var rehideTimer: Timer?
    /// One "rehide: deferred" line per armed countdown, not one per re-arm.
    private var rehideDeferLogged = false
    private var statusItem: PelmetStatusItem?
    private var separators: SeparatorManager?
    private(set) var helperHosts: HelperHosts?
    /// Set once the first converge has run: helper registrations before it
    /// are covered by the boot wait, later ones need an adoption window.
    private var engineStarted = false
    private var extras: ExtrasManager?
    private var bandMonitor: MenuBarBandMonitor?
    private var clockRelay: ClockClickRelay?
    /// See `ClockClickRelay.lastMouseDownDisplay`: the display whose bar
    /// macOS draws active. nil until the first click after launch.
    var lastMouseDownDisplay: CGDirectDisplayID? { clockRelay?.lastMouseDownDisplay }
    private var hotkey: HotkeyManager?
    private var showRules: ShowRules?
    private var eventTask: Task<Void, Never>?
    @ObservationIgnored private lazy var accessibility = AccessibilityMonitor { [weak self] granted in
        self?.accessibilityChanged(granted)
    }

    // MARK: - Lifecycle

    /// Boot sequence. ORDER IS LOAD-BEARING:
    /// migrations → policy/updater → onboarding gate → bar items (separators
    /// before extras; extras sync reads the media-controls migration) →
    /// monitors → event pump → async engine boot. Inside the engine boot:
    /// `waitForOwnItemAdoption` runs BEFORE `engine.start` (items registering
    /// under an active assertion park offscreen), `registerNewItems` before
    /// `setModel` (routing must precede the first converge), and the launch
    /// conceal precedes the display-policy reveal so the policy lands on a
    /// settled bar.
    func start() {
        wireTransitionSettleCallbacks()
        runOneShotMigrations()
        applyPolicyAndStartUpdater()
        presentOnboardingIfNeeded()
        buildBarItems()
        startMonitors()
        grouper.start()
        startEngineEventPump()
        bootEngine()
        observeDebugOpenMenu()
        observeDebugPicturePass()
        observeDebugToggle()
    }

    /// Panel dev trigger: with `pelmet.debug.toggle` set at launch, the
    /// distributed notification `app.fif7y.Pelmet.debug.toggle` toggles the
    /// reveal as if its object (`hover`, `hotkey`, else a click) asked;
    /// `bar` reveals Hidden on the real bar, as ⌘↩ in Search does.
    private func observeDebugToggle() {
        guard UserDefaults.standard.bool(forKey: "pelmet.debug.toggle") else { return }
        debugToggleObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.fif7y.Pelmet.debug.toggle"), object: nil, queue: .main
        ) { [weak self] note in
            let object = note.object as? String
            let reason: RevealReason = switch object {
            case "hover": .hover
            case "hotkey": .hotkey
            case "bar": .itemInBar
            default: .click
            }
            MainActor.assumeIsolated {
                if reason == .itemInBar {
                    self?.reveal([.hidden], reason: reason)
                } else {
                    self?.toggle(reason: reason)
                }
            }
        }
        debugPanelShotObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.fif7y.Pelmet.debug.panelShot"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.panelPresenter.debugShot() }
            }
        }
        PelmetLog.log("panel: debug toggle on — app.fif7y.Pelmet.debug.toggle, .panelShot")
    }

    @ObservationIgnored private var debugToggleObserver: NSObjectProtocol?
    @ObservationIgnored private var debugPanelShotObserver: NSObjectProtocol?

    /// Panel spike S1: `defaults write app.fif7y.Pelmet pelmet.debug.picturePass
    /// -bool YES`, relaunch, then post `app.fif7y.Pelmet.debug.picturePass`
    /// (object `always`: Always Hidden too).
    private func observeDebugPicturePass() {
        guard UserDefaults.standard.bool(forKey: "pelmet.debug.picturePass") else { return }
        debugPicturePassObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.fif7y.Pelmet.debug.picturePass"), object: nil, queue: .main
        ) { [weak self] note in
            let always = note.object as? String == "always"
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.transitions.debugPicturePass(always: always) }
            }
        }
        PelmetLog.log("pass: debug trigger on — app.fif7y.Pelmet.debug.picturePass")
    }

    @ObservationIgnored private var debugPicturePassObserver: NSObjectProtocol?

    private func wireTransitionSettleCallbacks() {
        ConcealGhostOverlay.onHeldBarClick = { [weak self] display, clicks in
            self?.heldBarClicked(display: display, clickCount: clicks)
        }
        ConcealGhostOverlay.iconLayout = { [weak self] in
            guard let self else { return [] }
            let frames = (chevronWindowFrame.map { [$0] } ?? []) + (snapshot?.items.compactMap(\.frame) ?? [])
            return frames.map { Int(($0.minX * 2).rounded()) * 10_000 + Int(($0.width * 2).rounded()) }.sorted()
        }
        transitions.onRevealSettled = { [weak self] in
            guard let self else { return }
            dispatch(rehide.handle(.transitionSettled))
            settleCatchUp()
            placeOwnItemsAwaitingReveal()
            // Swipe-through hover: the pointer can be long gone by the
            // time the reveal settles — armIfNeeded gave the FULL delay.
            // Re-arm as a pointer-out so an accidental hover self-heals
            // on the short clock. HOVER ONLY: deliberate reveals (click,
            // hotkey) with the pointer elsewhere must keep the floor,
            // not conceal instantly at rehideDelay 0.
            if case .revealed(_, .hover) = rehide.state,
               bandMonitor?.pointerCurrentlyInBand == false {
                pointerLeftBand()
            }
        }
        transitions.onConcealSettled = { [weak self] in
            guard let self else { return }
            dispatch(rehide.handle(.transitionSettled))
            settleCatchUp()
            if launchBaselineApplied { reconcileAnchor("conceal settled") }
            // Rapid hover out-in: if the pointer is back in the band by the
            // time this conceal lands, its entry edge is spent — re-arm the
            // hover reveal so the bar doesn't stay shut under the pointer.
            if case .concealed = rehide.state {
                bandMonitor?.rearmHoverAfterConceal()
            }
            liveMirror.kick()
        }
        // Settled as concealed: left `.revealed([])`, hover stayed dead.
        transitions.onNothingRevealed = { [weak self] in
            guard let self else { return }
            dispatch(rehide.handle(.nothingCameOut))
            settleCatchUp()
            if case .concealed = rehide.state {
                bandMonitor?.rearmHoverAfterConceal()
            }
        }
    }

    /// `X.Y.Z-beta.N` builds (RELEASE.md § Beta).
    static var isPrereleaseBuild: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.contains("-") ?? false
    }

    private func runOneShotMigrations() {
        // One-shot: snappier hover default (0.2 → 0.1) for stores saved
        // before the default changed.
        if !UserDefaults.standard.bool(forKey: "pelmet.migratedHoverDelay01"),
           abs(settings.revealTriggers.hoverDelay - 0.2) < 0.011 {
            settings.revealTriggers.hoverDelay = 0.1
            settings.save()
        }
        UserDefaults.standard.set(true, forKey: "pelmet.migratedHoverDelay01")

        // A beta build turns "Get beta releases" on, once per store: whoever
        // runs one took it from GitHub or from the channel itself, and with
        // the toggle off the next stable would drop them out of the betas.
        // Their own later choice stands (the seed never re-runs).
        if Self.isPrereleaseBuild {
            if !UserDefaults.standard.bool(forKey: "pelmet.seededBetaOptIn"), !settings.betaUpdates {
                settings.betaUpdates = true
                settings.save()
                PelmetLog.log("start: beta build, Get beta releases turned on")
            }
            UserDefaults.standard.set(true, forKey: "pelmet.seededBetaOptIn")
        }

        // Sliders are stepped now (hover 0.1–0.5): snap stores saved under
        // the old free ranges onto the grid. Hide again is a menu of 0, 0.5,
        // 1, 2, 3 or 5 seconds: a 0.5-step store showed the nearest one checked
        // while the bar waited its own, and picking that one changed nothing.
        settings.revealTriggers.hoverDelay = (min(max(settings.revealTriggers.hoverDelay, 0.1), 0.5) * 10).rounded() / 10
        let rehide = RehideChoice.snapped(settings.rehideDelay)
        if rehide != settings.rehideDelay {
            PelmetLog.log("start: Hide again \(settings.rehideDelay)s snapped to the menu's \(rehide)s")
            settings.rehideDelay = rehide
        }

        // One-shot (#86): the "while active" rule of Focus and Time Machine
        // used to take the icon away when idle; now it only brings it out.
        // One in Visible moves to Hidden, where it still shows while active.
        // A hidden Time Machine showed only while backing up AND revealed,
        // so it drops the rule and doesn't start coming out on its own. A
        // hidden Focus came out on its own while on: dropping its rule
        // inverted that, which the Focus one-shot below puts back.
        if !UserDefaults.standard.bool(forKey: "pelmet.migratedShowRuleMeaning") {
            for index in settings.extraItems.indices {
                let spec = settings.extraItems[index]
                guard spec.kind.showsWhenItMatters, spec.resolvedShowRule == .whenActive else { continue }
                let key = ExtrasManager.itemID(for: spec).sectionKey
                if settings.sectionModel.section(of: key) == .visible {
                    settings.sectionModel.enroll(key, in: .hidden)
                } else {
                    settings.extraItems[index].showRule = .always
                }
                PelmetLog.log("start: \(spec.itemTitle) rule now only brings it out, \(settings.sectionModel.section(of: key)) \(settings.extraItems[index].resolvedShowRule)")
            }
            UserDefaults.standard.set(true, forKey: "pelmet.migratedShowRuleMeaning")
        }

        // One-shot (review REM-1, Gab: "keep their bars"): 0.3.1's Focus came
        // out while a Focus was on from any section, and beta.5's migration
        // above flipped a hidden one to never. Every hidden Focus gets
        // "While a Focus is on" back; new installs keep the opt-in default.
        if !UserDefaults.standard.bool(forKey: "pelmet.migratedFocusKeepsBar032") {
            let changed = settings.keepFocusOutWhileActive()
            if !changed.isEmpty { settings.save() }
            UserDefaults.standard.set(true, forKey: "pelmet.migratedFocusKeepsBar032")
            PelmetLog.log(changed.isEmpty
                ? "migrate: focus keeps its bar — nothing to change"
                : "migrate: focus keeps its bar — Focus in \(changed.map(\.rawValue)) now shows while a Focus is on (whenActive)")
        }

        // An icon's shortcut on ⌘A/C/V/X/Z or ⇧⌘Z took that edit from every
        // app; the recorder refuses them now, and one an older build saved
        // is dropped here (once: it's gone from the store after).
        let editChords = settings.itemHotkeys.filter { ShortcutRecorder.isEditChord($0.value) }
        if !editChords.isEmpty {
            for key in editChords.keys { settings.itemHotkeys.removeValue(forKey: key) }
            PelmetLog.log("start: dropped edit shortcuts from icons: \(editChords.map { "\($0.key) \($0.value.display)" }.sorted().joined(separator: ", "))")
        }

        // Migrate the model to canonical (bundle-level) keys — collapses any
        // title-variant twin entries left by older builds.
        settings.sectionModel.canonicalize()
        settings.save()
    }

    private func applyPolicyAndStartUpdater() {
        rehide.policy = settings.rehidePolicy
        engineCanHide = engine.capabilities.canHide
        PelmetLog.log("start: axTrusted=\(accessibilityGranted) canHide=\(engineCanHide) assignments=\(settings.sectionModel.assignments.count)")
        SparkleController.shared.notifyOnUpdates = { [weak self] in self?.settings.notifyOnUpdates ?? true }
        SparkleController.shared.openUpdateHub = { [weak self] in self?.openSettings(tab: .about) }
        SparkleController.shared.betaUpdates = { [weak self] in self?.settings.betaUpdates ?? false }
        SparkleController.shared.onStatusChange = { [weak self] status in
            if case .available = status {
                self?.statusItem?.showUpdateDot(true)
            } else {
                self?.statusItem?.showUpdateDot(false)
            }
        }
        SparkleController.shared.start()
    }

    /// First run gets the intro. A finished install that lost its grant
    /// (an update re-signed the bundle, the toggle was flipped) gets the
    /// one-step recovery instead of the whole intro again.
    private func presentOnboardingIfNeeded() {
        if !settings.onboardingCompleted {
            OnboardingController.shared.present(appState: self, mode: .intro)
        } else if !accessibilityGranted {
            OnboardingController.shared.present(appState: self, mode: .accessRecovery)
        }
    }

    private func buildBarItems() {
        if settings.showStatusItem {
            statusItem = PelmetStatusItem(appState: self)
        }
        ConcealGhostOverlay.prewarmDisplay()
        helperHosts = HelperHosts(appState: self)
        separators = SeparatorManager(appState: self)
        separators?.sync(with: settings.separators)
        // Migration: early builds had a bare media-controls bool.
        if settings.showMediaControls, !settings.extraItems.contains(where: { $0.kind == .mediaControls }) {
            settings.showMediaControls = false
            addExtra(ExtraItemSpec(kind: .mediaControls))
        }
        // Repair: blobs written by builds that appended a spec without an
        // order slot (#13). Every extra gets one where the model already
        // places it — nothing moves.
        var repaired = false
        for spec in settings.extraItems {
            repaired = settings.sectionModel.enroll(ExtrasManager.itemID(for: spec).sectionKey) || repaired
        }
        // The other side of the invariant: a removed extra left its order
        // key behind (twenty dead launcher keys in one blob). Separators
        // have their own manager and stay.
        let liveExtraKeys = Set(settings.extraItems.map { ExtrasManager.itemID(for: $0).sectionKey })
        // A singleton kind (Siri, Time Machine, timer…) keeps one key for
        // life: its section survives the toggle going off, so on again it
        // returns where the user had it (a boot with Siri off sent it to
        // Visible, 2026-09-21). Launchers and shortcuts are one key each.
        let singletonKeys = Set(ExtraKind.allCases.filter { $0 != .shortcut && $0 != .appLauncher }
            .map { ExtrasManager.itemID(for: ExtraItemSpec(kind: $0)).sectionKey })
        for (section, order) in settings.sectionModel.order {
            let kept = order.filter {
                !MenuBarPolicy.isPelmetExtraID($0) || $0.isPelmetSeparator || liveExtraKeys.contains($0)
            }
            if kept.count != order.count {
                settings.sectionModel.order[section] = kept
                for key in order where !kept.contains(key) && !singletonKeys.contains(key) {
                    settings.sectionModel.assignments.removeValue(forKey: key)
                }
                repaired = true
            }
        }
        if repaired {
            PelmetLog.log("extras: order slots repaired")
            settings.save()
        }
        extras = ExtrasManager(appState: self)
        extras?.sync(with: settings.extraItems)
    }

    private func startMonitors() {
        accessibility.start()
        let bandMonitor = MenuBarBandMonitor(appState: self)
        bandMonitor.start()
        self.bandMonitor = bandMonitor

        let clockRelay = ClockClickRelay { [weak self] point, pointer, option in
            self?.clockClicked(at: point, pointer: pointer, option: option)
        }
        // The tap always runs (it is also the active-display observer);
        // the setting only decides whether a clock click is relayed.
        clockRelay.setEnabled(settings.clockClickOpensNotificationCenter)
        self.clockRelay = clockRelay

        let hotkey = HotkeyManager { [weak self] slot in
            switch slot {
            case .toggle: self?.toggle(reason: .hotkey)
            case .settings: self?.openSettings()
            case .notificationCenter: self?.openNotificationCenter()
            case .alwaysHidden: self?.toggleAll(reason: .hotkey)
            case .search:
                // Settings › Search in front: the demo there takes it.
                if let self, self.searchDemo.isInFront, !self.commandBar.isOpen {
                    // Scrolled into view: the pane may be down at the list.
                    self.settingsFocusRow = "searchDemo"
                    self.searchDemo.focus()
                } else {
                    self?.commandBar.toggle(source: "hotkey")
                }
            }
        }
        hotkeyConflict = !hotkey.register(settings.hotkey, slot: .toggle)
        settingsHotkeyConflict = !hotkey.register(settings.settingsHotkey, slot: .settings)
        alwaysHiddenHotkeyConflict = !hotkey.register(settings.alwaysHiddenHotkey, slot: .alwaysHidden)
        notificationCenterHotkeyConflict = !hotkey.register(activeNotificationCenterHotkey, slot: .notificationCenter)
        searchHotkeyConflict = !hotkey.register(settings.searchHotkey, slot: .search)
        registeredHotkey = settings.hotkey
        registeredSettingsHotkey = settings.settingsHotkey
        registeredAlwaysHiddenHotkey = settings.alwaysHiddenHotkey
        registeredNotificationCenterHotkey = activeNotificationCenterHotkey
        registeredSearchHotkey = settings.searchHotkey
        self.hotkey = hotkey
        hotkey.onItemTrigger = { [weak self] slot in self?.itemHotkeyFired(slot) }
        syncItemHotkeys()
        // The command bar's panel is built once things have settled, not on
        // the first shortcut.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.commandBar.warm() }

        // A relaunched app's status item is a FRESH registration made under
        // the assertion — it parks offscreen until an adoption window lets
        // the agent attach it (see `adoptRelaunchedBundle`).
        let agents = Self.systemAgentBundles(in: NSWorkspace.shared.runningApplications)
        MenuBarPolicy.registerSystemAgents(agents)
        PelmetLog.log("policy: \(agents.count) system agent(s) registered from \(MenuBarPolicy.systemAgentLocation)")
        relaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MenuBarPolicy.registerSystemAgents(Self.systemAgentBundles(in: [app]))
            guard let bundle = app.bundleIdentifier, Self.isBundleMainProcess(app) else { return }
            MainActor.assumeIsolated { self?.adoptRelaunchedBundle(bundle) }
        }
        // Battery, Wi-Fi and Apple's other icons come and go from System
        // Settings › Menu Bar with no launch to announce them: MenuBarAgent
        // was running all along. Leaving System Settings is when the bar may
        // have changed, so it is walked then, and an icon that came or went
        // lands as itemsChanged like any other (2026-10-12).
        systemSettingsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.systempreferences" else { return }
            MainActor.assumeIsolated { self?.walkAfterSystemSettings() }
        }
        readAppleMenuBarSwitches()
        observeRunningApplications()
        if let capture = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == MenuBarPolicy.screenCaptureUIID }) {
            watchRecordingPill(capture)
        }
        watchChevronHosting()
    }

    /// The Stop Recording pill registers under the assertion and parks, and
    /// comes and goes with no walk (`RecordingPill`): adopt it as the
    /// recording starts, walk the bar as it shows or leaves.
    private func watchRecordingPill(_ capture: NSRunningApplication) {
        recordingPill.onRecordingStarted = { [weak self] in
            guard let self else { return }
            PelmetLog.log("recording: started, adopting the pill")
            Task { await self.adoptRecordingPill() }
        }
        recordingPill.onIconsChanged = { [weak self] count in
            PelmetLog.log("recording: pill \(count > 0 ? "up" : "gone"), walking")
            Task {
                _ = await self?.engine.freshSnapshot()
                // The walk at the stop can land mid-teardown and still list it.
                guard count == 0 else { return }
                try? await Task.sleep(for: .seconds(1))
                _ = await self?.engine.freshSnapshot()
            }
        }
        recordingPill.onEnded = { [weak self] in
            PelmetLog.log("recording: screencaptureui quit, walking")
            Task { _ = await self?.engine.freshSnapshot() }
        }
        recordingPill.follow(capture)
    }

    private let recordingPill = RecordingPill()

    /// The pill registers at the far left of the bar, every recording, and
    /// no section holds it: it goes to the chevron end of Visible once, as
    /// soon as it settles and the user's hands are off (2026-10-22), and a
    /// held picture keeps it out of sight until it lands. One drag per
    /// recording, no budget; off with "keep sections grouped", where it
    /// stays put and in sight.
    private func adoptRecordingPill() async {
        let placing = SectionGrouper.isOn
        transitions.placingSectionless = placing
        defer { transitions.placingSectionless = false }
        guard await coveringAdoption({ await engine.openAdoptionWindow(for: MenuBarPolicy.screenCaptureUIID) }) else { return }
        updateSnapshot(await engine.snapshot())
        if placing { await placeRecordingPill() }
    }

    private func placeRecordingPill() async {
        let deadline = ContinuousClock.now + .seconds(10)
        var waiting = "no walk at rest"
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            let snap = await engine.freshSnapshot()
            let pill = Set(ApplyPass.primaryFrames(snap, appState: self).keys.filter {
                $0.bundleID == MenuBarPolicy.screenCaptureUIID
            })
            guard snap.itemsAtRest else { waiting = "no walk at rest"; continue }
            guard !pill.isEmpty else { waiting = "no pill on the bar"; continue }
            // The agent keeps the slot it was dragged to (its trailing
            // positions, 2026-10-22): from the second recording on it comes
            // up there.
            guard !ApplyPass.plan(for: self, snapshot: snap, strays: pill).moves.isEmpty else {
                PelmetLog.log("recording: pill already in Visible")
                return
            }
            guard ApplyPass.secondsSinceAnyInput() >= AppTiming.applyIdleGap else { waiting = "input"; continue }
            updateSnapshot(snap)
            transitions.heldPassClicks = true
            let report = await runGroupingPass(.strays(pill))
            transitions.heldPassClicks = false
            guard let report, !report.abandoned else { waiting = "input"; continue }
            PelmetLog.log("recording: pill \(report.applied.isEmpty ? "not moved" : "moved to Visible")")
            return
        }
        PelmetLog.log("recording: pill left where it is — 10s with \(waiting)")
    }

    /// One walk a second after the last time System Settings lost focus:
    /// granting a permission flips between it and Pelmet a few times.
    private func walkAfterSystemSettings() {
        readAppleMenuBarSwitches()
        systemSettingsWalk?.cancel()
        systemSettingsWalk = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            PelmetLog.log("bar: left System Settings, walking for icons it added or removed")
            _ = await self.engine.freshSnapshot()
        }
    }

    private var systemSettingsWalk: Task<Void, Never>?

    /// Battery's and Wi-Fi's switches in System Settings › Menu Bar, by
    /// item. A concealed icon is out of the AX tree, so no walk tells one
    /// switched off from one hidden (both in Always Hidden, 2026-10-12).
    /// Empty until read, and where macOS keeps no value.
    private(set) var appleMenuBarSwitches: [ItemID: Bool] = [:]

    /// `-currentHost com.apple.controlcenter` holds 2 for an icon shown in
    /// the bar and 8 for one switched off, written as the box is ticked
    /// (read live on macOS 27.2, 2026-10-12).
    private func readAppleMenuBarSwitches() {
        let domain = "com.apple.controlcenter" as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        var switches: [ItemID: Bool] = [:]
        for (id, key) in [(ShowRules.battery, "Battery"), (ShowRules.wifi, "WiFi")] {
            guard let value = CFPreferencesCopyValue(
                key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
            ) as? Int else { continue }
            switches[id.sectionKey] = value & 2 != 0
        }
        guard switches != appleMenuBarSwitches else { return }
        appleMenuBarSwitches = switches
        let line = switches.map { "\($0.key.rawValue)=\($0.value ? "on" : "off")" }.sorted().joined(separator: " ")
        PelmetLog.log("bar: System Settings › Menu Bar switches \(line)")
    }

    /// The process is the app itself, not a child LaunchServices filed
    /// under its parent's bundle: an `osascript` or `open` spawned by an
    /// app runs as that app's bundle id with its own executable. Claude
    /// Desktop's tool runs spawn one every few seconds, and each read as a
    /// relaunch — an adoption window per spawn, the assertion dropped and
    /// every hidden icon flashed under a cover (2026-09-18).
    /// Bundle ids of the processes that live where macOS keeps its menu bar
    /// agents (`MenuBarPolicy.systemAgentLocation`).
    nonisolated static func systemAgentBundles(in apps: [NSRunningApplication]) -> Set<String> {
        Set(apps.compactMap { app in
            guard let id = app.bundleIdentifier, let path = app.bundleURL?.standardizedFileURL.path,
                  MenuBarPolicy.isSystemAgentLocation(path) else { return nil }
            return id
        })
    }

    nonisolated static func isBundleMainProcess(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL, let exe = app.executableURL,
              let own = Bundle(url: bundleURL)?.executableURL else { return true }
        return own.standardizedFileURL.path == exe.standardizedFileURL.path
    }

    private var relaunchObserver: NSObjectProtocol?
    private var systemSettingsObserver: NSObjectProtocol?
    private var runningAppsObservation: NSKeyValueObservation?
    private var lastRelaunchQueue: [String: Date] = [:]
    private var siblingLaunchLogged: Set<String> = []
    private var chevronHostObservers: [NSObjectProtocol] = []
    private var chevronHostCheck: Task<Void, Never>?
    /// When the chevron was last re-hosted, for `ChevronHosting.budget`.
    private var chevronRehosts: [Date] = []
    private var rehostingChevron = false
    /// The last "not re-hosted" line, logged once per change.
    private var chevronHostNote: String?
    /// Debug: `open -a Dimble --args -pelmet.debug.forceChevronRehost YES`
    /// re-hosts a chevron that's on the bar, once, at the next wake, unlock
    /// or display change: the re-host path, on a Mac that never drops it.
    private var debugForceChevronRehost = UserDefaults.standard.bool(forKey: "pelmet.debug.forceChevronRehost")

    /// Menu-bar agent apps (LSUIElement / background-only) post no launch
    /// notification — Snib, OpenClip and Sconce relaunched all afternoon
    /// without a single adoption (2026-09-09). KVO on runningApplications
    /// sees every activation policy; both paths feed the same window.
    private func observeRunningApplications() {
        runningAppsObservation = NSWorkspace.shared.observe(
            \.runningApplications, options: [.old, .new]
        ) { [weak self] _, change in
            let before = Set((change.oldValue ?? []).compactMap(\.bundleIdentifier))
            // `newValue` is the CHANGE (the inserted or removed apps), not
            // the array — pushed as the running set it emptied the engine's
            // allowlist to two bundles (2026-09-21 11:38). Read the whole
            // list.
            let now = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            Task { [engine = self?.engine] in await engine?.setRunningBundles(now) }
            if let capture = (change.newValue ?? []).first(where: { $0.bundleIdentifier == MenuBarPolicy.screenCaptureUIID }) {
                Task { @MainActor [weak self] in self?.watchRecordingPill(capture) }
            }
            let quit = before.subtracting(now)
            if !quit.isEmpty { Task { @MainActor [weak self] in self?.appsQuit(quit) } }
            let appeared = (change.newValue ?? [])
                .filter { Self.isBundleMainProcess($0) }
                .compactMap(\.bundleIdentifier)
                .filter { !before.contains($0) }
            guard !appeared.isEmpty else { return }
            Task { @MainActor [weak self] in
                for bundle in appeared { self?.adoptRelaunchedBundle(bundle) }
            }
        }
    }

    /// A known item that is in the model but absent from the bar even when
    /// its section is revealed has re-registered under the assertion and
    /// parked (ChatGPT Classic re-creates its status item at runtime, 2026-09-09;
    /// the icon showed for a moment and never came back). Same remedy as a
    /// relaunch: a brief adoption window.
    /// An adoption window drops the assertion outright — the agent refuses to
    /// attach a newly registered item while ANY assertion is held, allowlist
    /// or not — so for its whole life (up to 2.5s) every hidden AND
    /// always-hidden icon is back in the bar. Float the same picture the
    /// clock blink uses over the strip for the round trip. #31: a relaunched
    /// always-hidden app showed its icon "for a second" on the next hover —
    /// the hover was a coincidence, the retry window was the flash.
    private func coveringAdoption(_ body: () async -> Bool) async -> Bool {
        guard await engine.holdsAssertion else { return await body() }
        let cover = await transitions.beginBarCover(
            label: "adopt", safety: AppTiming.adoptionCoverSafety
        )
        let adopted = await body()
        if let cover { transitions.endBarCover(cover, label: "adopt") }
        return adopted
    }

    func reopenAdoption(for bundle: String) async {
        if await coveringAdoption({ await engine.openAdoptionWindow(for: bundle) }) {
            absentBundles.remove(bundle)
            updateSnapshot(await engine.snapshot())
        } else {
            // Running, assigned, and still no registration with the
            // assertion dropped: the app has no bar icon right now (its
            // "show in menu bar" is off — the launcher flow's last step).
            // The editor's no-flash guard must not keep a ghost tile for it.
            absentBundles.insert(bundle)
            PelmetLog.log("editor: \(bundle) has no menu bar item — off the board")
        }
    }

    static func relaunchAdoptionKeys(for bundle: String, model: SectionModel) -> [ItemID] {
        // A system host may restart before any registration pass has folded
        // it into knownBundles (the input menu switched on, then its agent
        // relaunched). Its assignment is the proof the user manages it.
        guard MenuBarPolicy.isUnmanagedAppleBundle(bundle) || model.knownBundles.contains(bundle) else { return [] }
        return registrationCandidates(model.assignments.keys.filter { $0.bundleID == bundle })
    }

    static func registrationCandidates(_ items: [ItemID]) -> [ItemID] {
        items.filter {
            guard let bundle = $0.bundleID else { return false }
            return !PelmetBundle.ownIDs.contains(bundle) && MenuBarPolicy.isSectionManageable($0)
        }
    }

    /// Bundles that are running but proven icon-less (an adoption window
    /// found no registration). Cleared the moment an item of theirs shows.
    private var absentBundles: Set<String> = []
    /// When each canonical identity was last live or concealed. The editor
    /// keeps a stored item's stand-in tile through a snapshot gap only while
    /// this is fresh; a host with no registration never gets one.
    private var lastSeenAt: [ItemID: Date] = [:]
    private static let storedTileGrace: TimeInterval = 15
    /// The process that last owned each bundle's live item. A launch
    /// notification names a bundle, not a process: while this pid still
    /// runs, the item it owns is merely concealed and the "relaunch" is a
    /// sibling reusing the id.
    private var lastSeenPID: [String: pid_t] = [:]

    private func adoptRelaunchedBundle(_ bundle: String) {
        let keys = Self.relaunchAdoptionKeys(for: bundle, model: settings.sectionModel)
        guard !keys.isEmpty else { return }
        // The notification and the KVO path can both report one launch.
        if let last = lastRelaunchQueue[bundle], Date.now.timeIntervalSince(last) < 3 { return }
        lastRelaunchQueue[bundle] = .now
        let queuedAt = Date.now
        // The relaunched item registers UNDER an active assertion and parks
        // offscreen — it never enters the bar or the AX tree on its own (so
        // no itemsChanged fires, and the editor can't see it either). Open
        // an explicit adoption window once the app has had time to build its
        // item; retry once for slow bootstraps (Electron vault apps take
        // ~20s). Skipped when the item is already observable.
        Task { [weak self] in
            for delay in [AppTiming.relaunchAdoptionDelay, AppTiming.relaunchAdoptionRetry] {
                try? await Task.sleep(for: delay)
                guard let self else { return }
                // LIVE AX presence only — the engine's carried concealed set
                // still lists the OLD registration (a concealed item's quit
                // fires no AX event, so nothing pruned it) and would mask the
                // parked NEW one. A relaunched item is parked, never
                // genuinely concealed, until an assertion-free gap adopts it.
                let snap = await self.engine.snapshot()
                let observable = snap.items.contains { $0.id.bundleID == bundle }
                if observable { return }
                // The owner of the bundle's item is still running, so the
                // item is concealed, not parked: nothing relaunched. Proton
                // Drive ships a launchd KeepAlive agent that respawns a
                // second "Proton Drive" every 10s which quits on sight of
                // the first — each spawn dropped the assertion and flashed
                // every hidden icon (issue #12). Checked after the delay,
                // not at queue time: a self-relaunching app's old process
                // can outlive its successor's launch notification.
                if let pid = self.lastSeenPID[bundle], kill(pid, 0) == 0 {
                    if self.siblingLaunchLogged.insert(bundle).inserted {
                        PelmetLog.log("adoptWindow: \(bundle) owner pid=\(pid) still running — sibling launch, nothing to adopt (logged once)")
                    }
                    return
                }
                // No owner pid on record (an item Pelmet only ever saw
                // through the agent's tree — Electron apps with AX off):
                // an instance of the app older than this launch is still
                // up, so the item is concealed, not parked.
                if self.lastSeenPID[bundle] == nil,
                   NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: {
                       Self.isBundleMainProcess($0) && ($0.launchDate ?? .now) < queuedAt.addingTimeInterval(-1)
                   }) {
                    if self.siblingLaunchLogged.insert(bundle).inserted {
                        PelmetLog.log("adoptWindow: \(bundle) an older instance is still running — sibling launch, nothing to adopt (logged once)")
                    }
                    return
                }
                // A system host (the input menu's agent) registers through
                // the agent's own path the moment it has an item — it never
                // parks and never bootstraps slowly. After the first wait it
                // is either registered and already concealed or it
                // restarted without an item (the
                // menu switched off in System Settings). Neither needs the
                // assertion dropped, let alone twice (2026-09-10). The
                // pinned hosts get nothing from a window either: the slot
                // they come back to is the one macOS gives them. Apple's
                // ordinary helpers DO park, and fall through like any app.
                if MenuBarPolicy.isPositionPinnedAppleBundle(bundle) {
                    let held = snap.concealed.contains { $0.bundleID == bundle }
                    PelmetLog.log("adoptWindow: \(bundle) \(held ? "registered and concealed" : "restarted without its item") — nothing to adopt")
                    return
                }
                if await self.coveringAdoption({ await self.engine.openAdoptionWindow(for: bundle) }) {
                    self.updateSnapshot(await self.engine.snapshot())
                    return
                }
            }
            PelmetLog.log("adoptWindow: \(bundle) never registered — giving up")
        }
    }

    /// A lid closed on external displays and opened on the built-in alone
    /// left the chevron on no bar until a relaunch (#26, cpierce). Each
    /// wake, unlock or display change looks again once the bar settles.
    private func watchChevronHosting() {
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, why) in [(NSWorkspace.didWakeNotification, "wake"),
                            (NSWorkspace.screensDidWakeNotification, "displays woke")] {
            chevronHostObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleChevronHostCheck(why)
                    self?.scheduleAnchorCheck(why)
                }
            })
        }
        chevronHostObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.transitions.dropHeldBars("display change")
                self?.chevronDisplaysChanged()
                self?.scheduleChevronHostCheck("display change")
                self?.scheduleAnchorCheck("display change")
            }
        })
        chevronHostObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleChevronHostCheck("screen unlocked")
                self?.scheduleAnchorCheck("screen unlocked")
            }
        })
        // The chevron's window loses `.visible` the moment macOS puts it
        // behind the «, and gets it back when there's room (#81).
        chevronHostObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let window, window == self.statusItem?.buttonWindow.map(ObjectIdentifier.init) else { return }
                self.checkChevronTrap()
            }
        })
    }

    /// Displays come and go in a burst: once they have settled, the bar is
    /// anchored for a display that shows all icons or not, and the held
    /// pictures go back up at the new geometry.
    @ObservationIgnored private var anchorCheck: Task<Void, Never>?
    private func scheduleAnchorCheck(_ why: String) {
        anchorCheck?.cancel()
        anchorCheck = Task { [weak self] in
            try? await Task.sleep(for: AppTiming.chevronHostCheckDelay)
            guard !Task.isCancelled, let self, self.launchBaselineApplied else { return }
            self.reconcileAnchor(why)
            self.transitions.refreshHeld(why)
        }
    }

    /// The last event wins: a wake, a display change and an unlock come in
    /// a burst, and only the settled bar is worth a look.
    private func scheduleChevronHostCheck(_ why: String) {
        chevronHostCheck?.cancel()
        chevronHostCheck = Task { [weak self] in
            try? await Task.sleep(for: AppTiming.chevronHostCheckDelay)
            guard !Task.isCancelled, let self else { return }
            await self.checkChevronHosted(after: why)
        }
    }

    private func chevronHostingVerdict() async -> (verdict: ChevronHosting.Verdict, detail: String) {
        let snap = await engine.snapshot()
        let drawn = statusItem?.windowFrame
        chevronRehosts.removeAll { Date.now.timeIntervalSince($0) > ChevronHosting.budgetWindow }
        let verdict = ChevronHosting.verdict(
            drawn: drawn, screens: NSScreen.screens.map(\.frame), walkedItems: snap.items.count,
            walkedChevron: pelmetChevronItem(in: snap) != nil, recentRehosts: chevronRehosts.count
        )
        let window = drawn.map { "window at x=\(Int($0.minX)) y=\(Int($0.minY))" } ?? "no window"
        return (verdict, "\(window), walk \(snap.items.count) item(s), \(NSScreen.screens.count) display(s)")
    }

    private func checkChevronHosted(after why: String) async {
        guard settings.showStatusItem, statusItem != nil, engineStarted, !rehostingChevron else { return }
        guard !barInFlux else {
            scheduleChevronHostCheck(why)
            return
        }
        var (verdict, detail) = await chevronHostingVerdict()
        if verdict == .rehost {
            // Once more after a beat: the agent may still be re-hosting it.
            PelmetLog.log("chevron: not on any bar after \(why) (\(detail)) — looking once more")
            try? await Task.sleep(for: AppTiming.chevronHostConfirmDelay)
            guard !Task.isCancelled, settings.showStatusItem, statusItem != nil, !rehostingChevron else { return }
            (verdict, detail) = await chevronHostingVerdict()
        }
        if verdict == .hosted, debugForceChevronRehost {
            debugForceChevronRehost = false
            verdict = .rehost
            detail += ", forced by pelmet.debug.forceChevronRehost"
        }
        switch verdict {
        case .hosted:
            if chevronHostNote != nil { PelmetLog.log("chevron: on the bar again after \(why) (\(detail))") }
            chevronHostNote = nil
        case .wait(let reason):
            let note = "chevron: not on any bar after \(why), not re-hosted: \(reason)"
            if note != chevronHostNote { PelmetLog.log("\(note) (\(detail))") }
            chevronHostNote = note
        case .rehost:
            // Its own task: a later event cancels the check, and a cancelled
            // sleep inside the adoption window would spin its walks.
            Task { [weak self] in await self?.rehostChevron(after: why, detail: detail) }
        }
    }

    /// What a relaunch does for the chevron, without the relaunch: a fresh
    /// registration, then an adoption window, since the agent parks an item
    /// registered under the assertion (`bootEngine`).
    private func rehostChevron(after why: String, detail: String) async {
        guard !rehostingChevron, settings.showStatusItem, statusItem != nil else { return }
        rehostingChevron = true
        defer { rehostingChevron = false }
        chevronRehosts.append(.now)
        PelmetLog.log("chevron: still not on any bar after \(why) (\(detail)) — re-hosting (\(chevronRehosts.count)/\(ChevronHosting.budget))")
        statusItem?.remove()
        statusItem = PelmetStatusItem(appState: self)
        statusItem?.updateSymbol(revealed: isRevealedOrRevealing)
        _ = await coveringAdoption { await engine.openAdoptionWindow(for: PelmetBundle.mainID, expecting: Self.chevronItemID) }
        updateSnapshot(await engine.snapshot())
        let after = await chevronHostingVerdict()
        chevronHostNote = after.verdict == .hosted ? nil : "re-hosted, still off"
        PelmetLog.log("chevron: re-hosted — \(after.verdict == .hosted ? "on the bar" : "still not on any bar") (\(after.detail))")
    }

    private func startEngineEventPump() {
        eventTask = Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                self?.handle(engineEvent: event)
            }
        }
    }

    private func bootEngine() {
        Task {
            // The agent DEFERS adopting newly registered status items while
            // an assessment assertion is active (verified live 2026-08-21: a
            // fresh item parks offscreen until no assertion holds, then lands
            // instantly). Pelmet's own items re-register at every launch, and
            // the first converge would assert before adoption lands — parking
            // them for the whole session.
            await helperHosts?.waitUntilHosted()
            await waitForOwnItemAdoption()
            await engine.start()
            engineStarted = true
            // Extras change size inside the same agent reflow as assertion
            // swaps — the only way their motion matches everything else's.
            await engine.setReflowCompanion { [weak self] revealed in
                guard let self else { return }
                PelmetLog.log("companion: fired revealed=\(revealed.map(\.rawValue).sorted())")
                self.extras?.apply(
                    model: self.settings.sectionModel,
                    revealed: revealed,
                    systemCameraPillVisible: self.systemCameraPillVisible
                )
                self.separators?.apply(
                    model: self.settings.sectionModel,
                    revealed: revealed
                )
            }
            await engine.setSteadyExtras(settings.effectiveHideSystemExtras)
            if !settings.hideSystemExtras, settings.replacesCollateralExtras {
                PelmetLog.log("extras: system extras held hidden — a Pelmet item replaces one")
            }
            // Apps that first appeared while Pelmet wasn't running route to the
            // new-items section before the first converge. Nothing moves:
            // membership hides them where they sit (docs/CORE-SETS.md).
            let launchSnapshot = await engine.snapshot()
            registerNewItems(from: launchSnapshot)
            // The panel's tile order, read off the bar while every section
            // is on it (#104). Memory only, it was empty after a launch: the
            // first open drew the model's order (concealed icons have no
            // frame, so their ids decided it) and the picture pass re-sorted
            // the tiles under the pointer. Phantoms behind the « are left
            // out (`ApplyPass.primaryFrames`) and keep their stored slot.
            recordDrawnOrder(launchSnapshot, revealed: [.hidden, .alwaysHidden])
            // Last look at the fully live bar: the first reveal's picture
            // (see TransitionCoordinator.takeBootPicture). The converge
            // below is what conceals.
            await transitions.takeBootPicture(from: launchSnapshot)
            await engine.setModel(settings.sectionModel)
            updateSnapshot(await engine.snapshot())
            // Startup state: everything the model says is hidden, is hidden.
            dispatch(rehide.handle(.concealRequested))
            // Through the coordinator: the pictures hold the bar as it was.
            showRules = ShowRules { [transitions] items in
                transitions.showRuleChanged(items)
            }
            showRules?.update(settings.showRules)
            transitions.warmAfterBoot(from: launchSnapshot)
            // Launch baseline: the band monitor applies display behavior on
            // crossings, and on its first sighting only from here on, so the
            // display Pelmet launches under gets its policy applied here
            // (queued behind the conceal's settle).
            if revealAnchored {
                reconcileAnchor("launch")
            } else if pointerDisplayBehavior == .alwaysShowAll {
                reveal([.hidden], reason: .displayPolicy)
            }
            bandMonitor?.seedPointerDisplay()
            launchBaselineApplied = true
        }
    }

    /// The launch has applied the display policy for the display under the
    /// pointer, after its conceal: the band monitor's first sighting of a
    /// display applies it from now on (`DisplayCrossing`). Before, a reveal
    /// would land ahead of the conceal it must follow, and the baseline
    /// above reads the pointer where it is by then.
    @ObservationIgnored private(set) var launchBaselineApplied = false

    /// Async teardown for app termination: dropping the assertion restores
    /// the user's menubar. Caller returned .terminateLater — this replies
    /// when the engine has stopped, or at the deadline, whichever first
    /// (formerly a main-actor-blocking semaphore).
    private var terminationReplied = false
    func beginTermination() {
        rehideTimer?.invalidate()
        eventTask?.cancel()
        SparkleController.shared.clearUpdateNotification()
        Task { [engine] in
            await engine.stop()
            self.replyTerminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + AppTiming.terminationStopDeadline) { [weak self] in
            self?.replyTerminate()
        }
    }

    private func replyTerminate() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: - Intents (UI + monitors call these)

    func toggle(reason: RevealReason, sections: Set<PelmetCore.Section> = [.hidden]) {
        if liveMirror.intercepts(reveal: reason, sections: sections, how: .toggle) { return }
        // A chevron click on a display that shows all icons opens Always
        // Hidden there, in that display's "Show hidden icons in" (#96). A plain toggle
        // asked for nothing when anchored, and closed the icons that display
        // shows when the pointer's display decided.
        if RevealRouting.clickWidensToAlwaysHidden(reason, sections: sections, behavior: pointerDisplayBehavior) {
            PelmetLog.log("toggle(\(reason)) on a display that shows all icons — Always Hidden too")
            toggleAll(reason: reason)
            return
        }
        if anchoredShowAllAsksNothing(sections, reason) { return }
        PerfTrace.markTrigger("\(reason)")
        // A click landing in the first moments of a hover reveal: the
        // pointer reached the chevron, the hover fired ~100ms later, and
        // the click was already on its way. The machine's rule for a
        // toggle mid-transition (the opposite of where we're heading)
        // read it as "close" — open, shut, then the hover on the chevron
        // opened it again (2026-09-18). Take it as the same reveal, now
        // the click's.
        let hoverSections: Set<PelmetCore.Section>? = {
            switch rehide.state {
            case .transitioning(target: .reveal(let sections, .hover), queued: nil): sections
            case .revealed(let sections, .hover): sections
            default: nil
            }
        }()
        if let hoverSections, let started = hoverRevealStartedAt,
           Date().timeIntervalSince(started) < AppTiming.hoverRevealClickGrace {
            PelmetLog.log("toggle(\(reason)) \(Int(Date().timeIntervalSince(started) * 1000))ms into a hover reveal — taken as the same reveal")
            dispatch(rehide.handle(.revealRequested(hoverSections, reason)))
            // The panel the hover opened is the click's now: keys and all.
            if panelShowsReveal { panelPresenter.makeDeliberate() }
            return
        }
        let effects = rehide.handle(.toggleRequested(sections, reason))
        PelmetLog.log("toggle(\(reason)) state=\(rehide.state) effects=\(effects)")
        dispatch(effects)
        // A deliberate conceal under a hovering pointer must STAY concealed:
        // the pointer is in the band by definition (it just clicked there),
        // and the conceal-settle hover re-arm would reopen the bar at once —
        // every chevron click read as a dead click (2026-09-06).
        if effects.contains(.conceal) {
            bandMonitor?.suppressHoverUntilPointerLeaves()
        }
    }

    /// Anchored, a display that shows all icons has them out already: a
    /// hover or a click on its bar asks for nothing.
    private func anchoredShowAllAsksNothing(_ sections: Set<PelmetCore.Section>, _ reason: RevealReason) -> Bool {
        guard transitions.anchored, case .concealed = rehide.state, RevealRouting.startsAtBar(reason),
              sections.isSubset(of: transitions.anchoredSections),
              pointerDisplayBehavior == .alwaysShowAll else { return false }
        return true
    }

    func reveal(_ sections: Set<PelmetCore.Section>, reason: RevealReason) {
        if liveMirror.intercepts(reveal: reason, sections: sections, how: .reveal) { return }
        if anchoredShowAllAsksNothing(sections, reason) { return }
        PerfTrace.markTrigger("\(reason)")
        // The panel is up and this needs the real bar (⌘↩ in Search, an
        // Apply): the panel closes first and the reveal queues behind it. A
        // request for the panel's own sections would otherwise change
        // nothing, and the bar would never come out.
        if panelShowsReveal, case .revealed = rehide.state, RevealRouting.needsBar(reason) {
            dispatch(rehide.handle(.concealRequested))
        }
        dispatch(rehide.handle(.revealRequested(sections, reason)))
        if panelShowsReveal, reason != .hover { panelPresenter.makeDeliberate() }
    }

    /// The Always Hidden shortcut (#67): everything out, or everything back
    /// once it is all out. A reveal that left Always Hidden in widens to
    /// include it instead of closing: the key asked for more, not less.
    func toggleAll(reason: RevealReason) {
        if liveMirror.intercepts(reveal: reason, sections: [.hidden, .alwaysHidden], how: .toggleAll) { return }
        let all: Set<PelmetCore.Section> = [.hidden, .alwaysHidden]
        // Off the anchor (no Screen Recording), a display that shows all
        // icons has its Hidden out as the policy's own bar reveal (#96). A
        // click there that follows a panel or a row takes that reveal down
        // and opens there: widening the bar ignored the setting until a
        // third click. Closing Always Hidden goes back to the policy's
        // reveal, not to an empty bar.
        if !transitions.anchored, pointerDisplayBehavior == .alwaysShowAll, revealPresenter === barPresenter,
           case .revealed(let current, let by) = rehide.state {
            let target = revealDecision(for: reason).target
            if by == .displayPolicy, !current.contains(.alwaysHidden),
               RevealRouting.destination(for: reason, target: target) == .panel {
                PelmetLog.log("toggleAll(\(reason)) off the anchor — the policy's bar goes, \(target.rawValue) opens")
                concealNow()
                reveal(all, reason: reason)
                return
            }
            if current.contains(.alwaysHidden), current.contains(.hidden) {
                dispatch(rehide.handle(.narrowRequested([.hidden], .displayPolicy)))
                PelmetLog.log("toggleAll(\(reason)) off the anchor — narrowed to the policy's reveal, state=\(rehide.state)")
                return
            }
        }
        let showing: Set<PelmetCore.Section>? = {
            switch rehide.state {
            case .revealed(let sections, _): sections
            case .transitioning(target: .reveal(let sections, _), queued: nil): sections
            default: nil
            }
        }()
        if let showing, !showing.contains(.alwaysHidden) {
            reveal(all, reason: reason)
        } else {
            toggle(reason: reason, sections: all)
        }
    }

    /// The panel folded away a section the reveal asked for (Always Hidden
    /// after a ⌥-click): the machine stops counting it as out, so a ⌥-click,
    /// a double-click or its shortcut brings it back instead of finding it
    /// there already.
    func sectionsPutAway(_ sections: Set<PelmetCore.Section>) {
        dispatch(rehide.handle(.sectionsPutAway(sections)))
        PelmetLog.log("put away \(sections.map(\.rawValue).sorted()) state=\(rehide.state)")
    }

    /// When the last hover reveal's effect started — the earliest the user
    /// could see the bar open (see `toggle`).
    private var hoverRevealStartedAt: Date?

    /// Open an item's menu where it sits, whichever section it is in: on
    /// the bar it is clicked, concealed it is brought back alone beneath a
    /// cover for the click and put away once its menu is gone (ItemPress).
    /// Pelmet's own extras run their own action instead of a click.
    /// `.secondary` is the right click. The clock opens Notification Center
    /// the way its shortcut does: a click on it is refused while the
    /// assertion is held. `display`: the one the press was made from (the
    /// panel's), whose bar's copy is clicked so the menu opens there (#26).
    func openItemMenu(_ id: ItemID, button: ItemPress.Button = .primary, display: CGDirectDisplayID? = nil) {
        if button == .primary, id.rawValue.hasSuffix("::com.apple.menuextra.clock") {
            openNotificationCenter()
            return
        }
        // A picture pass has the bar revealed under its cover: the press
        // waits for it, or both would reveal and conceal at once.
        if transitions.passInFlight {
            transitions.passWaiterArrived()
            Task {
                await transitions.awaitPicturePass()
                press.open(id, button: button, display: display)
            }
            return
        }
        press.open(id, button: button, display: display)
    }

    /// Show an item in the bar without clicking it. The icon comes out alone,
    /// in its own spot, and goes back on the rules a section reveal follows
    /// (the rehide machine's countdown, pointer and click elsewhere). Apps and
    /// system items come out through the engine's item reveal; Pelmet's own
    /// extras through the extras manager, which hides them by their own
    /// visibility (an extra whose own rule keeps it out of the bar, such as
    /// media with nothing playing, is left alone). Separators and the chevron
    /// open their section the way the hotkey opens it (Always Hidden with
    /// Hidden, as the Always Hidden shortcut does). Its own reason, so a
    /// panel setting never swallows the reveal.
    func showItemInBar(_ id: ItemID, passWaited: Bool = false) {
        let key = id.sectionKey
        let section = settings.sectionModel.section(of: key)
        guard section != .visible else {
            PelmetLog.log("press: show \(key.rawValue) — already in the visible section")
            return
        }
        // A picture pass has the bar revealed under its cover, so an extra
        // reads as already out and the pick would be dropped: it waits, as
        // a press does (`openItemMenu`).
        if !passWaited, transitions.passInFlight {
            transitions.passWaiterArrived()
            PelmetLog.log("press: show \(key.rawValue) — waits for the picture pass")
            Task {
                await transitions.awaitPicturePass()
                showItemInBar(id, passWaited: true)
            }
            return
        }
        // An Apply pass owns the bar's frames; the section reveal queues
        // behind it as it always did.
        if !applying {
            if MenuBarPolicy.canRevealAlone(key) {
                bringItemOut(key, section: section, waited: false)
                return
            }
            switch extras?.aloneOutcome(for: key) {
            case .ready:
                bringItemOut(key, section: section, waited: false)
                return
            case .showing:
                PelmetLog.log("press: show \(key.rawValue) — already out")
                return
            case .gated:
                PelmetLog.log("press: show \(key.rawValue) — its own rule keeps it out of the bar, nothing to bring out")
                return
            case nil:
                break
            }
        }
        let wanted: Set<PelmetCore.Section> = section == .alwaysHidden ? [.hidden, .alwaysHidden] : [.hidden]
        guard !wanted.isSubset(of: currentRevealedSections) else {
            PelmetLog.log("press: show \(key.rawValue) — its section is already revealed")
            return
        }
        PelmetLog.log("press: show \(key.rawValue) — revealing \(wanted.map(\.rawValue).sorted())")
        reveal(wanted.union(currentRevealedSections), reason: .itemInBar)
    }

    /// `waited`: this already waited out a reveal in flight once.
    private func bringItemOut(_ key: ItemID, section: PelmetCore.Section, waited: Bool) {
        guard !currentRevealedSections.contains(section), !itemsInBar.contains(key) else {
            PelmetLog.log("press: show \(key.rawValue) — already out")
            return
        }
        // A reveal on its way lands first: the icon then joins it, or is
        // already part of it.
        if !waited, case .transitioning(target: .reveal, _) = rehide.state {
            Task {
                let by = Date().addingTimeInterval(AppTiming.pressTransitionWait)
                while isTransitioning, Date() < by { try? await Task.sleep(for: .milliseconds(30)) }
                bringItemOut(key, section: section, waited: true)
            }
            return
        }
        // The panel is up and this is for the real bar: it closes first, and
        // takes no icon with it (the key joins the set after its conceal).
        if panelShowsReveal, case .revealed = rehide.state {
            dispatch(rehide.handle(.concealRequested))
        }
        PelmetLog.log("press: show \(key.rawValue) — on its own, \(section.rawValue) stays concealed")
        if itemsInBar.isEmpty { transitions.pressBegan() }
        itemsInBar.insert(key)
        switch rehide.state {
        case .revealed:
            // The bar is out already (sections, or another icon): this icon
            // joins it with no transition of the machine's, and the
            // countdown starts over for all of it.
            dispatch(rehide.handle(.revealRequested([], .itemInBar)))
            transitions.performItemsReveal([key], settles: false, trace: PerfTrace(kind: "reveal", reason: .itemInBar))
        case .transitioning(target: .reveal, _):
            // Still on its way after the wait: the machine would read this
            // as covered and drop it, so the icon is brought out directly.
            transitions.performItemsReveal([key], settles: false, trace: PerfTrace(kind: "reveal", reason: .itemInBar))
        default:
            // Concealed or concealing: the machine reveals no section and
            // settles once the icon is out.
            reveal([], reason: .itemInBar)
        }
    }

    /// The icons Show in Menu Bar has out, handed to whoever puts them back.
    /// Every one that takes a non-empty set ends the hold it left on the idle
    /// picture (`TransitionCoordinator.pressEnded`).
    private func takeItemsInBar() -> Set<ItemID> {
        defer { itemsInBar = [] }
        return itemsInBar
    }

    /// Icons held for a reveal the machine no longer has: it settled
    /// concealed, or the queued icon reveal was replaced or cancelled. They
    /// never came out through the machine, so a later Show would read
    /// "already out", the hold on the idle picture would stay up and every
    /// picture pass would be skipped. They go back quietly (nothing was
    /// seen) and end their hold.
    private func releaseOrphanedItemsInBar() {
        guard !itemsInBar.isEmpty else { return }
        switch rehide.state {
        case .concealed:
            break
        case .transitioning(target: .conceal, queued: .reveal(let sections, _)?):
            guard !sections.isEmpty else { return }
        case .transitioning(target: .conceal, queued: _):
            break
        default:
            return
        }
        let stale = takeItemsInBar()
        PelmetLog.log("press: show — \(stale.count) icon(s) held for a reveal that never ran, released")
        let own = stale.filter(isOwnExtra)
        releaseExtrasAlone(own)
        let theirs = stale.subtracting(own)
        Task {
            if !theirs.isEmpty { await engine.conceal(items: theirs) }
            transitions.pressEnded()
        }
    }

    /// Icons Show in Menu Bar has out that left the bar by themselves: their
    /// app quit, or an extra's own rule ended (media stopped). When that was
    /// all of it, the empty reveal ends through the normal icon conceal, or
    /// hover would stay dead and the pointer on the bar would hold nothing
    /// open. Otherwise the rest stays out and the gone ones are let go.
    private func itemsLeftBar(_ keys: Set<ItemID>) {
        let gone = itemsInBar.filter { held in keys.contains { $0.sectionKey == held.sectionKey } }
        guard !gone.isEmpty else { return }
        PelmetLog.log("press: show — \(gone.map(\.rawValue).sorted()) left the bar by themselves")
        let onlyIcons: Bool
        switch rehide.state {
        case .revealed(let sections, _): onlyIcons = sections.isEmpty
        case .transitioning(target: .reveal(let sections, _), queued: nil): onlyIcons = sections.isEmpty
        default: onlyIcons = false
        }
        if gone.count == itemsInBar.count, onlyIcons {
            // The conceal takes the set, gone ones included, and releases it.
            dispatch(rehide.handle(.concealRequested))
            return
        }
        itemsInBar.subtract(gone)
        let ends = itemsInBar.isEmpty
        let theirs = gone.filter { !isOwnExtra($0) }
        Task {
            // The engine still lists the app's icon as brought out.
            if !theirs.isEmpty { await engine.conceal(items: Set(theirs)) }
            if ends { transitions.pressEnded() }
        }
    }

    /// The extras manager: these extras went out of the bar on their own.
    func ownItemsLeftBar(_ keys: Set<ItemID>) { itemsLeftBar(keys) }

    /// Apps that quit (running-applications KVO): their icons are gone.
    private func appsQuit(_ bundles: Set<String>) {
        guard !itemsInBar.isEmpty else { return }
        let gone = itemsInBar.filter { !isOwnExtra($0) && $0.bundleID.map(bundles.contains) == true }
        if !gone.isEmpty { itemsLeftBar(Set(gone)) }
    }

    // MARK: - Pelmet's own extras

    /// What a press on one of Pelmet's own extras needs first; nil when the
    /// key is no extra (a separator, the chevron), which keep the click.
    func ownPressNeed(_ key: ItemID, secondary: Bool) -> ExtrasManager.PressNeed? {
        extras?.pressNeed(itemKey: key, rightClick: secondary)
    }

    func isOwnExtraShowing(_ key: ItemID) -> Bool { extras?.isShowing(key) ?? false }

    /// One of the extras (Shortcuts, Siri, media, AirDrop…), not a separator
    /// or the chevron. Show in Menu Bar brings these out through the manager.
    func isOwnExtra(_ key: ItemID) -> Bool { extras?.manages(key) ?? false }
    func showExtrasAlone(_ keys: Set<ItemID>) { extras?.showAlone(keys) }
    func releaseExtrasAlone(_ keys: Set<ItemID>) { extras?.releaseAlone(keys) }
    func forgetExtrasAlone(_ keys: Set<ItemID>) { extras?.forgetAlone(keys) }

    /// False for one of Pelmet's own extras its section would not bring out
    /// (media controls with nothing playing); true for anything else.
    func ownExtraWouldShow(_ key: ItemID) -> Bool { extras?.wouldShow(key) ?? true }

    /// Runs the extra's own action, the one its button runs on a click.
    @discardableResult
    func activateExtra(_ key: ItemID, secondary: Bool) -> Bool {
        extras?.activate(itemKey: key, rightClick: secondary) ?? false
    }

    // MARK: - Per-item shortcuts

    /// Why a combination cannot become an item's shortcut.
    enum ItemHotkeyRefusal: Equatable {
        /// Already one of Pelmet's own shortcuts; carries what it does.
        case pelmet(String)
        /// Already another item's shortcut.
        case item(ItemID)
        /// macOS holds it (System Settings › Keyboard Shortcuts).
        case system
        /// Another app registered it first.
        case otherApp
    }

    /// Each item's shortcut opens its menu like a pick in the command bar.
    /// Slots count up from `HotkeyManager.itemSlotBase`; a combination another
    /// app holds is kept with no slot, so it is not retried on every settings
    /// change.
    private var itemHotkeyState: [String: (spec: HotkeySpec, slot: UInt32?)] = [:]
    private var nextItemHotkeySlot = HotkeyManager.itemSlotBase

    /// Brings the registrations in line with `settings.itemHotkeys`; cheap
    /// when nothing changed.
    func syncItemHotkeys() {
        guard let hotkey else { return }
        // Never an edit shortcut, whatever the store holds: it would take
        // Copy or Paste from every app.
        let wanted = settings.itemHotkeys.filter { !ShortcutRecorder.isEditChord($0.value) }
        for (key, state) in itemHotkeyState where wanted[key] != state.spec {
            if let slot = state.slot { hotkey.unregisterItem(slot: slot) }
            itemHotkeyState.removeValue(forKey: key)
        }
        for (key, spec) in wanted where itemHotkeyState[key] == nil {
            let slot = nextItemHotkeySlot
            let registered = hotkey.registerItem(spec, slot: slot)
            if registered { nextItemHotkeySlot += 1 }
            itemHotkeyState[key] = (spec, registered ? slot : nil)
        }
    }

    private func itemHotkeyFired(_ slot: UInt32) {
        guard let key = itemHotkeyState.first(where: { $0.value.slot == slot })?.key else { return }
        PelmetLog.log("hotkey: item shortcut → \(key)")
        openItemMenu(ItemID(rawValue: key))
    }

    /// Sets (or, with nil, removes) an item's shortcut. Nil back when it
    /// took; otherwise why not, with nothing changed.
    @discardableResult
    func setItemHotkey(_ spec: HotkeySpec?, for id: ItemID) -> ItemHotkeyRefusal? {
        let key = id.sectionKey.rawValue
        let previous = settings.itemHotkeys[key]
        if let spec {
            if let refusal = itemHotkeyRefusal(spec, for: key) { return refusal }
            settings.itemHotkeys[key] = spec
        } else {
            settings.itemHotkeys.removeValue(forKey: key)
        }
        syncItemHotkeys()
        if spec != nil, itemHotkeyState[key]?.slot == nil {
            // RegisterEventHotKey said no: another app holds it.
            settings.itemHotkeys[key] = previous
            syncItemHotkeys()
            return .otherApp
        }
        settings.save()
        PelmetLog.log("hotkey: item \(key) shortcut \(spec?.display ?? "removed")")
        return nil
    }

    private func itemHotkeyRefusal(_ spec: HotkeySpec, for key: String) -> ItemHotkeyRefusal? {
        func same(_ other: HotkeySpec?) -> Bool {
            other.map { $0.keyCode == spec.keyCode && $0.modifiers == spec.modifiers } ?? false
        }
        if same(settings.hotkey) { return .pelmet(String(localized: "Show Hidden Items")) }
        if same(settings.alwaysHiddenHotkey) { return .pelmet(String(localized: "Show Always Hidden Too")) }
        if same(settings.searchHotkey) { return .pelmet(String(localized: "Search the menu bar")) }
        if same(settings.settingsHotkey) { return .pelmet(String(localized: "Open Settings")) }
        if same(activeNotificationCenterHotkey) { return .pelmet(String(localized: "Open Notification Center")) }
        if let other = settings.itemHotkeys.first(where: { $0.key != key && same($0.value) })?.key {
            return .item(ItemID(rawValue: other))
        }
        return SystemShortcuts.owns(spec) ? .system : nil
    }

    /// The user's own name for an item; empty clears it.
    func setItemAlias(_ alias: String, for id: ItemID) {
        let key = id.sectionKey.rawValue
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            settings.itemAliases.removeValue(forKey: key)
        } else {
            settings.itemAliases[key] = String(trimmed.prefix(40))
        }
        settings.save()
        PelmetLog.log("search: alias for \(key) \(trimmed.isEmpty ? "removed" : "set")")
    }

    /// Debug: `defaults write app.fif7y.Pelmet pelmet.debug.openMenu -bool YES`,
    /// then relaunch. The distributed notification `app.fif7y.Pelmet.debug.openMenu`
    /// opens the menu of the item its object names (a section key or a bundle
    /// id; userInfo `button` = "secondary" for the right click), for testing
    /// the press without any UI. userInfo `action` = "show" runs Show in Menu
    /// Bar on it instead. Not observed unless the flag is set.
    private func observeDebugOpenMenu() {
        guard UserDefaults.standard.bool(forKey: "pelmet.debug.openMenu") else { return }
        debugOpenMenuObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.fif7y.Pelmet.debug.openMenu"), object: nil, queue: .main
        ) { [weak self] note in
            let name = note.object as? String
            let secondary = note.userInfo?["button"] as? String == "secondary"
            let show = note.userInfo?["action"] as? String == "show"
            MainActor.assumeIsolated { self?.debugOpenMenu(matching: name, secondary: secondary, show: show) }
        }
        PelmetLog.log("press: debug trigger on — app.fif7y.Pelmet.debug.openMenu")
    }

    @ObservationIgnored private var debugOpenMenuObserver: NSObjectProtocol?

    private func debugOpenMenu(matching name: String?, secondary: Bool, show: Bool = false) {
        guard let name, !name.isEmpty else {
            PelmetLog.log("press: debug — no item named in the notification's object")
            return
        }
        var ids = Set(settings.sectionModel.assignments.keys)
        for item in snapshot?.items ?? [] { ids.insert(item.id.sectionKey) }
        for id in snapshot?.concealed ?? [] { ids.insert(id.sectionKey) }
        let matches = ids.filter { $0.rawValue == name || $0.bundleID == name }.sorted { $0.rawValue < $1.rawValue }
        guard let id = matches.first else {
            PelmetLog.log("press: debug — no item matches \(name)")
            return
        }
        if matches.count > 1 { PelmetLog.log("press: debug — \(matches.count) items match \(name), taking \(id.rawValue)") }
        if show {
            showItemInBar(id)
        } else {
            openItemMenu(id, button: secondary ? .secondary : .primary)
        }
    }

    func concealNow() {
        PelmetLog.log("concealNow state=\(rehide.state)")
        dispatch(rehide.handle(.concealRequested))
    }

    func rehideTriggered(_ trigger: RehideTrigger) {
        PelmetLog.log("rehideTrigger(\(trigger)) state=\(rehide.state)")
        dispatch(rehide.handle(.trigger(trigger)))
    }

    func pointerReturnedToBand() {
        dispatch(rehide.handle(.pointerReturned))
    }

    func pointerEnteredHoverZone() {
        transitions.pointerApproachedBar()
    }

    func pointerLeftBand() {
        dispatch(rehide.handle(.pointerLeft))
    }

    /// Anything is out: a section, or only icons Show in Menu Bar brought out.
    var isRevealed: Bool {
        if case .revealed = rehide.state { return true }
        return false
    }

    /// A section is out. Icons alone don't count: the bar still reads as
    /// collapsed, and the chevron, a hover or a click opens the section.
    var sectionsRevealed: Bool {
        if case .revealed(let sections, _) = rehide.state { return !sections.isEmpty }
        return false
    }

    /// The chevron's drawn frame, nil with the icon off.
    var chevronWindowFrame: NSRect? { statusItem?.windowFrame }

    /// Revealed OR heading there — what the chevron should show.
    private var isRevealedOrRevealing: Bool {
        // Icons out on their own leave the chevron collapsed: no section is.
        switch rehide.state {
        case .revealed(let sections, _): return !sections.isEmpty
        case .transitioning(_, queued: .reveal(let sections, _)): return !sections.isEmpty
        case .transitioning(target: .reveal(let sections, _), queued: nil): return !sections.isEmpty
        default: return false
        }
    }

    /// Bounded poll until the engine reports swap-quiet for `interval` — the
    /// agent animates each swap, so quiet means the bar has stopped moving.
    /// Uncovered reveal: put the sections' own items (launchers, separators)
    /// into the layout before the swap, invisible, and give the agent a beat
    /// to place them — so its slide-in animates the third-party icons into
    /// slots around them instead of shifting everything once more when they
    /// settle later (see `StatusItemFader.attach`).
    /// Apply pass: idle extras join the layout invisibly so they can be
    /// dragged (ExtrasManager.attachForApply). Returns what joined.
    func attachIdleExtrasForApply() -> [ItemID] {
        let edits = settings.orderEdits
        return extras?.attachForApply(touched: { edits.touches($0.sectionKey) }) ?? []
    }
    func detachIdleExtrasAfterApply() { extras?.detachAfterApply() }

    func preattachOwnItems(revealing sections: Set<PelmetCore.Section>) async {
        let model = settings.sectionModel
        var attached = extras?.preattach(model: model, revealing: sections) ?? []
        attached += separators?.preattach(model: model, revealing: sections) ?? []
        guard !attached.isEmpty else { return }
        try? await Task.sleep(for: AppTiming.ownItemAttachLead)
        PelmetLog.log("preattach: \(attached.count) own item(s) in layout ahead of the swap")
    }

    func waitUntilQuiesced(
        interval: TimeInterval, deadline: TimeInterval, poll: Duration
    ) async {
        let by = Date().addingTimeInterval(deadline)
        while !Task.isCancelled, Date() < by, await !engine.quiesced(for: interval) {
            do {
                try await Task.sleep(for: poll)
            } catch {
                return
            }
        }
    }

    /// Post-settle catch-up: re-run the companion apply so anything that
    /// changed DURING the transition (media presence, camera pill, a converge
    /// that no-opped and never fired the companion) lands now. lastVisible
    /// guards make this a no-op when the companion already got it right.
    private func settleCatchUp() {
        extras?.apply(
            model: settings.sectionModel,
            revealed: currentRevealedSections,
            systemCameraPillVisible: systemCameraPillVisible
        )
        separators?.apply(model: settings.sectionModel, revealed: currentRevealedSections)
    }

    /// `row` is a setting the window should scroll to and mark once (the
    /// command bar's jump); the Settings view takes it and clears it.
    func openSettings(tab: SettingsTab = .general, row: String? = nil) {
        settingsFocusRow = row
        SettingsWindowController.shared.show(appState: self, tab: tab)
    }

    /// "Add a Shortcut…" on an icon: Settings › Search lists it, scrolls to
    /// its row and tints it. Nothing takes the focus: the pane arrives at
    /// rest, and the row says where to look.
    func openShortcut(for id: ItemID) {
        let key = id.sectionKey.rawValue
        if !pendingAliasItems.contains(key) { pendingAliasItems.append(key) }
        openSettings(tab: .search, row: SearchPane.rowAnchor(for: key))
    }

    func refreshAccessibility() {
        accessibility.refresh()
    }

    func refreshScreenRecording() {
        let granted = ScreenRecordingAccess.isGranted
        guard granted != screenRecordingGranted else { return }
        screenRecordingGranted = granted
        PelmetLog.log("screen: recording granted=\(granted)")
        extras?.screenRecordingChanged()
        if launchBaselineApplied { reconcileAnchor("screen recording \(granted ? "granted" : "lost")") }
    }

    /// Grant arrived: the engine's walks were empty until now, the clock
    /// relay's tap never came up, and the band's pointer tap was blind to
    /// other apps — re-read the bar, retry both taps, and re-apply the
    /// model. Grant lost: nothing to tear down (walks just go empty), but
    /// the status item and settings show the warning.
    private func accessibilityChanged(_ granted: Bool) {
        accessibilityGranted = granted
        PelmetLog.log("ax: trusted=\(granted)")
        statusItem?.updateAccessibilityWarning(granted: granted)
        guard granted else { return }
        clockRelay?.setEnabled(settings.clockClickOpensNotificationCenter)
        bandMonitor?.accessibilityGranted()
        Task {
            updateSnapshot(await engine.snapshot())
            await engine.setModel(settings.sectionModel)
            dispatch(rehide.handle(.concealRequested))
        }
    }

    private var settingsApplyWork: Task<Void, Never>?
    private var registeredHotkey: HotkeySpec?
    private var registeredSettingsHotkey: HotkeySpec?
    private var registeredAlwaysHiddenHotkey: HotkeySpec?
    private var registeredNotificationCenterHotkey: HotkeySpec?
    private var registeredSearchHotkey: HotkeySpec?
    /// The shortcut rides on the clock relay: off with it, not on its own.
    private var activeNotificationCenterHotkey: HotkeySpec? {
        settings.clockClickOpensNotificationCenter ? settings.notificationCenterHotkey : nil
    }

    /// Persist + apply a changed settings store. Cheap, latency-sensitive
    /// bits apply immediately; the save and the engine converge are debounced
    /// — slider drags call this per tick, and each un-debounced tick paid a
    /// JSON save plus a full AX-walking converge that concluded "no-op".
    /// Clock blink (see ClockClickRelay): cover the strip, drop the
    /// assertion, replay the swallowed click, re-acquire, lift the cover once
    /// the bar is quiet beneath it. With nothing held the click just replays.
    /// The Notification Center shortcut (#44): the OS one is refused while
    /// the assertion holds, whatever presses it. Runs the clock relay's
    /// dot-zone path — AX press on the clock, the pointer never moves —
    /// aimed at the clock's centre from the latest walk. Where the press
    /// does not keep the panel open (27.2 beta 3) it clicks the clock and
    /// puts the pointer back.
    private func openNotificationCenter() {
        guard let frame = snapshot?.items.first(where: { $0.id.rawValue.hasSuffix("::com.apple.menuextra.clock") })?.frame else {
            PelmetLog.log("clock: shortcut — no clock in the walk, nothing to press")
            return
        }
        var target = CGPoint(x: frame.midX, y: frame.midY)
        // The pointer's own place, in the clock's (top-left) space; a target
        // it happens to sit on replays a click there instead of pressing.
        let pointer = CGEvent(source: nil)?.location ?? CGPoint(x: -1, y: -1)
        // The walk keeps one clock, the main bar's. The panel belongs on
        // the display the pointer is on (#53: four bars, the panel kept
        // landing on the built-in): the system items sit in the same order
        // on every bar, so that display's clock is the same distance in
        // from its right edge. Hit-test before trusting it.
        if let display = ClockClickRelay.display(under: pointer),
           let main = ClockClickRelay.display(under: target), display != main {
            let mainBounds = CGDisplayBounds(main), bounds = CGDisplayBounds(display)
            let candidate = CGPoint(x: bounds.maxX - (mainBounds.maxX - target.x), y: bounds.minY + (target.y - mainBounds.minY))
            if ClockClickRelay.clockElement(at: candidate) != nil {
                target = candidate
            } else {
                PelmetLog.log("clock: shortcut — no clock at \(Int(candidate.x)),\(Int(candidate.y)) on display \(display), pressing the main bar's")
            }
        }
        guard ClockClickRelay.clockElement(at: target) != nil else {
            PelmetLog.log("clock: shortcut — nothing to press at \(Int(target.x)),\(Int(target.y)), no click replayed")
            return
        }
        PelmetLog.log("clock: shortcut → press at \(Int(target.x)),\(Int(target.y))")
        clockClicked(at: target, pointer: pointer == target ? CGPoint(x: -1, y: -1) : pointer, viaShortcut: true)
    }

    /// When the relay last opened the panel: the window list lags an
    /// opening by ~250ms, too slow for a second click right after.
    private var panelOpenedAt = Date.distantPast
    /// A blink is running: a second press meanwhile would raise a second
    /// cover over the first and press a clock that is already opening the
    /// panel (#52, #53: covers stacked six deep under a held shortcut).
    private var clockBlinkInFlight = false

    private func clockClicked(at point: CGPoint, pointer: CGPoint, option: Bool = false, viaShortcut: Bool = false) {
        Task { @MainActor in
            // Press the clock through AX so the pointer never moves; the
            // click is the fallback. Dot-zone clicks pressed since
            // 2026-09-19, clicks on the clock itself replayed at the spot
            // they landed, which dragged a hand that had moved on back to
            // it (#74). The element is resolved now, on a static bar.
            let clockElement = ClockClickRelay.clockElement(at: point)
            let panelWasOpen = ClockClickRelay.notificationCenterIsOpen() || Date().timeIntervalSince(panelOpenedAt) < 1
            // Where a replayed click lands: under the pointer while it is
            // still on the clock (no drag, nothing to put back), else the
            // target, with the pointer put back where the hand is now, not
            // where it clicked (a hand that had left was pulled back to the
            // clock). A close may land in the dot zone too, an open needs
            // the clock itself.
            // A ⌥-click goes out with its ⌥ (#92).
            let flags: CGEventFlags = option ? .maskAlternate : []
            let replayClick = { [clockRelay] (closing: Bool) in
                let live = CGEvent(source: nil)?.location
                if let live, clockRelay?.isOnClock(live, dotZoneIncluded: closing) == true {
                    ClockClickRelay.postClick(at: live, pointer: live, flags: flags)
                } else {
                    ClockClickRelay.postClick(at: point, pointer: live ?? pointer, flags: flags)
                }
            }
            // No clock under the target and another bar item under the
            // click: the zone outlived the clock's spot and took a
            // neighbour's click, Control Center reflowed into a hidden
            // clock's place (#93). Its click goes back as it was, with no
            // blink: a drop with no clock to press and no cover flashed
            // every hidden icon by.
            if clockElement == nil, !viaShortcut, let other = ClockClickRelay.otherBarItem(at: pointer) {
                await ClockClickRelay.waitForButtonRelease()
                let live = CGEvent(source: nil)?.location ?? pointer
                ClockClickRelay.postClick(at: pointer, pointer: live, flags: flags)
                PelmetLog.log("clock: click landed on \(other), not the clock — replayed as is, no blink")
                return
            }
            // Closing needs no blink: the panel dismisses itself on a click
            // outside it, and the assertion only refuses the clock's OWN
            // action. A plain replay of the click, no cover, no picture,
            // nothing for the panel's shade to disagree with (#51; live
            // 2026-09-22 15:33, 3/3). Opening stays a blink: with the
            // assertion held the clock's click is refused (probed 0/2). So
            // does a ⌥-click, the clock's own action whatever the panel does.
            if panelWasOpen, !option {
                await ClockClickRelay.waitForButtonRelease()
                replayClick(true)
                panelOpenedAt = .distantPast
                PelmetLog.log("clock: panel open — click replayed, no blink")
                // The bare bar is back once the panel has left (and its
                // window has left the list): the next click or reveal
                // should find a picture of it, not capture (#51).
                transitions.precaptureAfterPanel()
                // A real close takes the panel off the list well inside
                // 0.6s. One that still reads open is another window of the
                // same process (#81: 7–20 closes in a row with the panel
                // shut, so it never opened): marked phantom, the next click
                // takes the open path. A blink since is a new panel, not it.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard panelOpenedAt == .distantPast else { return }
                    let stuck = ClockClickRelay.markOpenWindowsPhantom()
                    guard !stuck.isEmpty else { return }
                    PelmetLog.log("clock: panel still reads open after a close — window(s) \(stuck.map(String.init).joined(separator: ", ")) marked phantom")
                }
                return
            }
            guard !clockBlinkInFlight else {
                PelmetLog.log("clock: blink in flight — press ignored")
                return
            }
            clockBlinkInFlight = true
            defer { clockBlinkInFlight = false }
            // A picture pass has the bar revealed under its cover: the blink
            // waits for it as a press does (`openItemMenu`), or its drop
            // would reflow Always Hidden under the pass (review APP-7).
            if transitions.passInFlight {
                transitions.passWaiterArrived()
                PelmetLog.log("clock: waits for the picture pass")
                await transitions.awaitPicturePass()
            }
            if !option { panelOpenedAt = Date() }
            let cover = await transitions.beginBarCover()
            // The physical click is swallowed, so the panel starts sliding
            // at Pelmet's own press and is in ~100ms later; from then on
            // the bar under it is static, and the cover swaps to a still
            // of that state (#51).
            let panelStarting = { [transitions] in
                guard let cover else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: AppTiming.panelSlideIn)
                    transitions.swapBlinkCoverUnderPanel(cover)
                }
            }
            var blinked = await engine.beginClockBlink()
            // When the press, not a replayed click, brought the panel up.
            var pressOpenedAt: Date?
            if option {
                // ⌥-click toggles Do Not Disturb (#92), refused while the
                // assertion is held like the plain click. The click goes
                // out with its ⌥ once the drop is in: no AX press (it
                // carries no modifiers) and no panel to wait for.
                await ClockClickRelay.waitForButtonRelease()
                try? await Task.sleep(for: AppTiming.clockPressSettle)
                replayClick(false)
                PelmetLog.log("clock: ⌥-click replayed\(blinked ? " with the assertion down" : "")")
            } else if ClockClickRelay.pressNeverOpensPanel {
                // This macOS never keeps the panel open on a press: replay
                // the click, once the button is up (the cover is often up
                // before the finger is, since the idle picture). The
                // shortcut clicks the clock too and puts the pointer back,
                // a one-frame jump over a dead ⌥⌘N (Gab, 2026-10-07).
                await ClockClickRelay.waitForButtonRelease()
                replayClick(false)
                panelStarting()
                PelmetLog.log("clock: click replayed — the press does not open the panel on this macOS")
            } else if let clockElement {
                // Only once the physical button is up: pressed while the
                // finger is still down (the tap swallows the up ~80ms
                // later), the clock merely highlighted. Then let the agent
                // apply the drop (the queued click got that latency for
                // free), and press once more if Notification Center has
                // not shown — the first press missed about one time in two
                // and the second always took (Gab, 2026-09-19).
                await ClockClickRelay.waitForButtonRelease()
                try? await Task.sleep(for: AppTiming.clockPressSettle)
                var opened = false
                // Presses that went out, waited their whole window with the
                // assertion still down, and brought no panel.
                var cleanMisses = 0
                var pressedAt = Date()
                for attempt in 1...2 where !opened {
                    pressedAt = Date()
                    // `pelmet.debug.clockPressNoop`: report the press sent
                    // without pressing, the way it lands on 27.0.x, to test
                    // that path on a macOS where the press works.
                    let pressed = UserDefaults.standard.bool(forKey: "pelmet.debug.clockPressNoop")
                        || ClockClickRelay.press(clockElement)
                    if pressed, attempt == 1 { panelStarting() }
                    // Poll for the panel rather than sleeping the whole
                    // verify budget: it shows well inside it, and every ms
                    // here is picture time on the bar (#46).
                    let verifyUntil = Date().addingTimeInterval(AppTiming.clockPressVerify)
                    repeat {
                        try? await Task.sleep(for: .milliseconds(30))
                        opened = ClockClickRelay.notificationCenterIsOpen()
                    } while !opened && Date() < verifyUntil
                    PelmetLog.log("clock: press \(attempt) \(pressed ? "sent" : "refused") - NC \(opened ? "open" : "not open")")
                    if pressed, !opened, await !engine.holdsAssertion { cleanMisses += 1 }
                }
                // Once per macOS build, the panel must still be up a moment
                // after the press: 27.2 beta 3 shows it and closes it on its
                // own (2026-10-07). This click and every later one on that
                // build replay, which keeps it.
                if opened, !ClockClickRelay.pressHoldsPanel {
                    var held = true
                    while held, Date() < pressedAt.addingTimeInterval(AppTiming.clockPressHold) {
                        try? await Task.sleep(for: .milliseconds(30))
                        held = ClockClickRelay.notificationCenterIsOpen()
                    }
                    if held {
                        ClockClickRelay.notePressHoldsPanel()
                    } else if ClockClickRelay.userInput(since: pressedAt) {
                        // A second ⌥⌘N or a click closed it: that says
                        // nothing about the press, and a replay would open
                        // the panel they just closed (review APP-5).
                        PelmetLog.log("clock: the panel left after the press, closed by the user — not counted, no replay")
                    } else {
                        PelmetLog.log("clock: the panel left on its own after the press")
                        ClockClickRelay.notePanelLeftAfterPress()
                        opened = false
                    }
                }
                if !opened {
                    // The drop's own reflow can converge and take the
                    // assertion back while the presses wait (the endClockBlink
                    // note), and the replay below would be refused too: drop
                    // it again first. A miss with the assertion back says
                    // nothing about the press; a clean one, then no panel by
                    // the end of the click, says this macOS never wires the
                    // press to it (#74, 27.0.1).
                    if await engine.holdsAssertion {
                        PelmetLog.log("clock: assertion back during the presses — dropped again for the click")
                        blinked = await engine.beginClockBlink() || blinked
                    }
                    if cleanMisses > 0 { ClockClickRelay.notePressNeverOpensPanel() }
                    replayClick(false); panelStarting()
                }
                if opened { pressOpenedAt = pressedAt }
            } else {
                PelmetLog.log("clock: no clock element under the target, replaying the click")
                replayClick(false)
                panelStarting()
            }
            guard blinked else { cover?.dismiss(); return }
            try? await Task.sleep(for: AppTiming.clockBlinkReacquire)
            await engine.endClockBlink()
            if let cover { transitions.endBarCover(cover) }
            // A panel the press opened must outlive the re-acquire too. On
            // 27.2 macOS can close it once the assertion is back, and a
            // build marked as holding never looked again, so every click
            // flashed the panel (#94). Gone with no input since counts like
            // a panel that left during the hold, and the second one turns
            // the build to replayed clicks. Its own task, so a click right
            // after isn't taken for one in flight.
            if let pressOpenedAt {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(AppTiming.clockPressHold))
                    if ClockClickRelay.notificationCenterIsOpen() {
                        PelmetLog.log("clock: panel still up after the re-acquire")
                    } else if ClockClickRelay.userInput(since: pressOpenedAt) {
                        PelmetLog.log("clock: panel closed by the user after the re-acquire — not counted")
                    } else {
                        PelmetLog.log("clock: the panel left on its own after the re-acquire")
                        ClockClickRelay.notePanelLeftAfterPress()
                    }
                }
            }
        }
    }

    /// The Live Activities item was clicked (#106): the bar comes out with
    /// the assertion let go, the only bar MenuBarAgent shows the pills on,
    /// live and clickable, and goes back the way any reveal does (the
    /// pointer leaves, the delay runs out, a click elsewhere). A blink like
    /// the camera relay's can't do it: the pill is the thing to see, not a
    /// panel that outlives the re-acquire. Every section comes out, Always
    /// Hidden too: with any assertion held the pills stay gone, so nothing
    /// can stay hidden while they show. Through the bar's own reveal, so it
    /// moves the way a ⌥-click does. A click while it is up, or on its way,
    /// puts it back at once: the lift's state is read here, not asked of the
    /// engine, which is mid-converge for the whole reveal.
    func liftHideForLiveActivities() {
        if liveMirror.interceptsItemClick() { return }
        let all: Set<PelmetCore.Section> = [.hidden, .alwaysHidden]
        if transitions.liftUp {
            PelmetLog.log("liveactivity: click with the bar lifted — concealing")
            concealNow()
            return
        }
        guard !liftStarting else {
            PelmetLog.log("liveactivity: click while the lift starts — left to it")
            return
        }
        liftStarting = true
        Task { @MainActor in
            defer { liftStarting = false }
            // Before anything moves: the picture the re-hide will show.
            await transitions.keepLiftPicture()
            if isRevealed, !panelShowsReveal, currentRevealedSections.isSuperset(of: all) {
                // Out already: no reveal is coming to carry the lift.
                PelmetLog.log("liveactivity: lift — the bar is out, the assertion goes")
                await transitions.liftOutBar()
                return
            }
            PelmetLog.log("liveactivity: lift — everything out with the assertion down")
            reveal(all, reason: .itemInBar)
            // After the request: the reveal's task, which runs later, takes it.
            transitions.liftRequestedAt = Date()
        }
    }
    /// From the lift's click until its reveal is asked for (the picture
    /// it keeps first).
    private var liftStarting = false

    /// The Live Activities watcher saw an activity start or end: `LiveMirror`
    /// enters or leaves when the bar allows, if the setting is on.
    func liveActivitiesChanged(running: Bool, count: Int = 0) {
        liveMirror.activitiesChanged(running: running, count: count)
    }

    /// A lift's re-hide has come to rest (`TransitionCoordinator.endLift`):
    /// the reads it held look at the bar again, and Camera & mic, kept on
    /// the bar beside Apple's pill, goes back to its own rule.
    func liftSettled() {
        overflowHoldEnded()
        guard !isTransitioning else { return }
        extras?.apply(model: settings.sectionModel, revealed: currentRevealedSections, systemCameraPillVisible: systemCameraPillVisible)
    }

    /// Set while the Camera & mic relay has the assertion down: Apple's
    /// pill is back on the bar for that moment, and Pelmet's item must not
    /// step aside for it (a reflow under the cover, and again after).
    private var audioVideoRelayActive = false
    /// Which relay the flag belongs to: only the latest one clears it.
    private var audioVideoRelayGeneration = 0

    /// The Camera & mic item was clicked: open Apple's own pill (#68) the
    /// way a clock click opens Notification Center, the assertion dropped
    /// under a picture of the bar and back once the panel is up. A SharePlay
    /// session passes Apple's SharePlay icon ahead of the pill. False when
    /// no pill or panel showed, for the caller's fallback.
    func openAudioVideoPill(near point: CGPoint, identifiers: [String] = [AudioVideoPill.identifier]) async -> Bool {
        guard !clockBlinkInFlight else {
            PelmetLog.log("audiovideo: blink in flight — press ignored")
            return true
        }
        clockBlinkInFlight = true
        audioVideoRelayActive = true
        audioVideoRelayGeneration += 1
        let generation = audioVideoRelayGeneration
        defer {
            clockBlinkInFlight = false
            Task { @MainActor in await settleAfterAudioVideoRelay(generation) }
        }
        // The agent answers AX only once the drop's reflow is done: the
        // pill came back 0.6–1.25s after it, and a cover on the usual 2.5s
        // safety faded before the re-acquire had hidden the bar again.
        let cover = await transitions.beginBarCover(
            label: "audiovideo",
            safety: AppTiming.transitionCoverSafety + AppTiming.audioVideoPillWait + AppTiming.clockPressVerify
        )
        let blinked = await engine.beginClockBlink(label: "audiovideo")
        let opened = await AudioVideoPill.open(near: point, identifiers: identifiers)
        guard blinked else { cover?.dismiss(); return opened }
        try? await Task.sleep(for: AppTiming.clockBlinkReacquire)
        await engine.endClockBlink()
        if let cover { transitions.endBarCover(cover, label: "audiovideo") }
        return opened
    }

    /// The re-acquire leaves AX mid-reflow for up to ~0.8s: Apple's pill
    /// and the revealed icons still listed, overlapping (read as icons
    /// behind the «), and that stale walk stayed the snapshot. Once the
    /// flag cleared on a timer, the next extras apply saw the pill "up" and
    /// Camera & mic stepped aside until the next reveal; a second relay
    /// inside the first one's timer lost the flag mid-drop the same way
    /// (#68, 2-3 clicks in a row). Hold the flag until a fresh walk shows
    /// the bar settled, keep that walk, re-apply, and only for the latest
    /// relay.
    private func settleAfterAudioVideoRelay(_ generation: Int) async {
        let deadline = Date().addingTimeInterval(AppTiming.clockBlinkCoverDeadline)
        let screenMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        func settled(_ snap: EngineSnapshot) -> Bool {
            let frames = snap.items.compactMap(\.frame).filter { $0.width > 4 && PlacementGeometry.isPrimary($0, screenMaxX: screenMaxX) }
            return !snap.items.contains { $0.id.rawValue.hasSuffix(AudioVideoPill.identifier) && $0.frame != nil }
                && PlacementGeometry.overflowTrapped(frames).isEmpty
        }
        var snap = await engine.freshSnapshot()
        var walks = 1
        while !settled(snap), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
            guard generation == audioVideoRelayGeneration else { return }
            snap = await engine.freshSnapshot()
            walks += 1
        }
        guard generation == audioVideoRelayGeneration else { return }
        PelmetLog.log("audiovideo: bar \(settled(snap) ? "settled" : "still unsettled at the deadline") after \(walks) walk(s)")
        updateSnapshot(snap)
        audioVideoRelayActive = false
        overflowHoldEnded()
        // A transition in flight re-applies at its settle catch-up.
        guard !isTransitioning else { return }
        extras?.apply(model: settings.sectionModel, revealed: currentRevealedSections, systemCameraPillVisible: systemCameraPillVisible)
    }

    // MARK: - Section helper events (HelperHosts)

    /// A helper registered an item. Mid-session that registration sits
    /// under an active assertion, which defers its adoption — open the
    /// window the way a relaunched app gets one.
    func helperHosted(title: String, bundle: String) {
        guard engineStarted else { return }
        Task {
            // Wait for THIS registration: the helper's other items were
            // adopted long ago and would satisfy a bundle-level check at
            // the first walk, closing the window before the new one lands.
            let live = ItemID.status(bundle: bundle, title: title)
            if await engine.openAdoptionWindow(for: bundle, expecting: live) {
                updateSnapshot(await engine.snapshot())
            }
        }
    }

    func helperItemClicked(title: String, rightButton: Bool, at point: NSPoint) {
        guard rightButton || separators?.spec(titled: title) != nil else { return }
        // Separators: either button opens Pelmet's menu (an always-available
        // settings entry point in iconless mode).
        let menu = PelmetStatusItem.contextMenu(appState: self)
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    func helperItemDraggedOff(title: String) {
        if let spec = separators?.spec(titled: title) {
            PelmetLog.log("separator: \(spec.style.displayName) dragged off the bar → remove")
            settings.separators.removeAll { $0.id == spec.id }
            settingsChanged()
        }
    }

    /// Pelmet's own chevron in the engine's id grammar.
    static let chevronItemID = ItemID(rawValue: "status:\(PelmetBundle.mainID)::Pelmet.StatusItem")

    /// A new separator lands where new icons land — the section the "New"
    /// chip sits in, at its front — instead of falling into Visible as an
    /// unassigned item (it showed up at the end of Visible, 2026-09-20).
    /// The separator just added from the editor: its tile opens its options
    /// once so people see the style and width are theirs to set.
    var newlyAddedSeparatorID: UUID?

    func addSeparator() {
        let spec = SeparatorSpec(style: .dot)
        settings.separators.append(spec)
        newlyAddedSeparatorID = spec.id
        var model = settings.sectionModel
        let home = model.newItemsDestination
        let key = SeparatorManager.itemID(for: spec).sectionKey
        if home != .visible { model.assignments[key] = home }
        // A new separator is a drawing like any drop: drawn at the front of
        // its section, moved there at Apply, forgotten by Discard. It used
        // to go through the own-item door at the next reveal, which read
        // as the bar changing by itself (Gab, 2026-09-21).
        // The edit starts from the bar's order (`barBasedOrder`) unless the
        // section already has a drawing pending.
        let before = settings.orderEdits.order[home] ?? barBasedOrder(in: home, model: model)
        var order = before
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
        model.order[home] = order
        settings.sectionModel = model
        if settings.orderEdits.previousOrder[home] == nil {
            settings.orderEdits.previousOrder[home] = before
        }
        settings.orderEdits.order[home] = order
        settings.orderEdits.created.insert(key)
        settings.orderEdits.dropped.insert(key)
        applyReport = nil
        settingsChanged()
        PelmetLog.log("editor: separator added → \(home), pending Apply")
    }

    func removeSeparator(_ id: UUID) {
        settings.separators.removeAll { $0.id == id }
        settingsChanged()
    }

    func settingsChanged() {
        rehide.policy = settings.rehidePolicy
        if settings.showStatusItem, statusItem == nil {
            // A chevron switched on mid-session is a fresh registration the
            // agent hosts from the order hint (a Pelmet relaunch seeds it
            // the same way); the chevron itself moves only by the user's
            // own ⌘-drag (docs/CORE-SETS.md §Own items).
            statusItem = PelmetStatusItem(appState: self)
        } else if !settings.showStatusItem {
            statusItem?.remove()
            statusItem = nil
        } else {
            statusItem?.updateSymbol(revealed: isRevealedOrRevealing)
        }
        // Re-registering unregisters first — a per-tick re-register left the
        // shortcut momentarily dead. Only touch it when it actually changed.
        if settings.hotkey != registeredHotkey {
            hotkeyConflict = !(hotkey?.register(settings.hotkey, slot: .toggle) ?? true)
            registeredHotkey = settings.hotkey
        }
        if settings.settingsHotkey != registeredSettingsHotkey {
            settingsHotkeyConflict = !(hotkey?.register(settings.settingsHotkey, slot: .settings) ?? true)
            registeredSettingsHotkey = settings.settingsHotkey
        }
        if settings.alwaysHiddenHotkey != registeredAlwaysHiddenHotkey {
            alwaysHiddenHotkeyConflict = !(hotkey?.register(settings.alwaysHiddenHotkey, slot: .alwaysHidden) ?? true)
            registeredAlwaysHiddenHotkey = settings.alwaysHiddenHotkey
        }
        if activeNotificationCenterHotkey != registeredNotificationCenterHotkey {
            notificationCenterHotkeyConflict = !(hotkey?.register(activeNotificationCenterHotkey, slot: .notificationCenter) ?? true)
            registeredNotificationCenterHotkey = activeNotificationCenterHotkey
        }
        if settings.searchHotkey != registeredSearchHotkey {
            searchHotkeyConflict = !(hotkey?.register(settings.searchHotkey, slot: .search) ?? true)
            registeredSearchHotkey = settings.searchHotkey
        }
        syncItemHotkeys()
        showRules?.update(settings.showRules)
        // Newly created separators and toggled-on extras get hosted wherever
        // macOS pleases (the order hint when it is fresh, the hidden side
        // when not): through the Apply door like any own item entering the
        // bar, one hidden-cursor drag while the user is still at the toggle.
        let previousOwnIDs = Set((extras?.managedItemIDs ?? []) + (separators?.managedItemIDs ?? []))
        // Before the extras sync: a setting turned off leaves live mode for
        // its own reason, ahead of the watcher stopping under it.
        liveMirror.settingChanged()
        separators?.sync(with: settings.separators)
        extras?.sync(with: settings.extraItems)
        pruneOrderEditsForRemovedOwnItems()
        let ownIDs = Set((extras?.managedItemIDs ?? []) + (separators?.managedItemIDs ?? []))
        // Separators are drawings: they move at Apply, never on their own.
        for id in ownIDs.subtracting(previousOwnIDs) where !id.isPelmetSeparator { placeOwnItemSoon(id) }
        clockRelay?.setEnabled(settings.clockClickOpensNotificationCenter)
        settingsApplyWork?.cancel()
        settingsApplyWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.settings.save()
            await self.engine.setSteadyExtras(self.settings.effectiveHideSystemExtras)
            await self.engine.setModel(self.settings.sectionModel)
        }
    }

    /// Settings-window close, tidy end, editor-tab close: the pointer
    /// display's policy decides between conceal and reveal — an unconditional
    /// conceal here collapsed the bar even on "always show everything"
    /// displays.
    func applyPointerDisplayPolicyAfterDismissal() {
        if !transitions.anchored, pointerDisplayBehavior == .alwaysShowAll {
            reveal([.hidden], reason: .displayPolicy)
        } else {
            concealNow()
        }
    }

    /// The panel closed with the pointer on a display that shows all icons,
    /// off the anchor: its Hidden comes back out on the bar, the policy's
    /// own reveal (#96). Nothing else brings it back before the next display
    /// crossing. Deferred, since this runs inside `dispatch`.
    private func restoreShowAllPolicyAfterPanel() {
        guard !transitions.anchored, pointerDisplayBehavior == .alwaysShowAll else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.transitions.anchored, self.pointerDisplayBehavior == .alwaysShowAll else { return }
            switch self.rehide.state {
            case .concealed, .transitioning(target: .conceal, queued: nil):
                PelmetLog.log("displays: panel closed on a display that shows all icons — back to the policy's reveal")
                self.reveal([.hidden], reason: .displayPolicy)
            default:
                break
            }
        }
    }

    /// What a pass opened, the pass closes: back to exactly what the pointer
    /// display's policy shows. A plain request keeps a wider reveal and its
    /// reason, so on a display set to always show, the pass's Always Hidden
    /// stayed out (`.settingsPreview`, whose rehide that policy defers for
    /// good) and every grouping pass after it waited on "the bar is
    /// revealed" (2026-10-13). The engine's reveal only adds: a settled
    /// reveal on the bar narrows to the policy's in one swap (Always Hidden
    /// goes back, Hidden stays). Concealing first and queueing the policy's
    /// reveal behind it reflowed the bar twice, read a transient "trapped
    /// Sound" and let a settle check see neither bar (live test,
    /// 2026-10-13). Anything else still conceals and re-reveals.
    func restoreDisplayPolicyAfterPass() {
        if !transitions.anchored, pointerDisplayBehavior == .alwaysShowAll, revealPresenter === barPresenter,
           case .revealed(let current, _) = rehide.state, current.contains(.hidden), current.count > 1 {
            dispatch(rehide.handle(.narrowRequested([.hidden], .displayPolicy)))
            PelmetLog.log("displays: pass over — narrowed to the policy's reveal, state=\(rehide.state)")
            return
        }
        concealNow()
        guard !transitions.anchored, pointerDisplayBehavior == .alwaysShowAll else { return }
        reveal([.hidden], reason: .displayPolicy)
        PelmetLog.log("displays: pass over — back to the policy's reveal, state=\(rehide.state)")
    }

    /// A Displays-tab picker changed: apply the pointer display's new policy
    /// live. Only the reveal side acts here — while the settings window is
    /// open nothing collapses under the user (existing rule); the collapse
    /// side lands on window close or the next display crossing.
    func displayBehaviorEdited() {
        PelmetLog.log("displays: behavior edited, pointer display=\(pointerDisplayBehavior)")
        if revealAnchored || transitions.anchored {
            reconcileAnchor("behavior edited")
            transitions.refreshHeld("behavior edited")
        } else if pointerDisplayBehavior == .alwaysShowAll {
            reveal([.hidden], reason: .displayPolicy)
        }
    }

    // MARK: - Layout editor intents

    /// Move an item to `section`, inserted before `beforeID` (nil = append).
    /// Updates assignment + drawn order; the bar moves at Apply.
    /// Bundles with an icon on the editor board (live or concealed) that
    /// Pelmet can actually manage — a launcher would be a duplicate. Icons
    /// marked incompatible are NOT here: those are exactly what launchers
    /// are for, and the user picks them before turning the original off.
    var manageableBarBundles: Set<String> {
        guard let snapshot else { return [] }
        let ids = snapshot.items.map(\.id) + Array(snapshot.concealed)
        return Set(
            ids.compactMap { id -> String? in
                guard let bundle = id.bundleID,
                      !PelmetBundle.ownIDs.contains(bundle),
                      !MenuBarPolicy.isUnmanagedAppleBundle(bundle),
                      // Apple's own hosts never get a launcher offer either.
                      !MenuBarPolicy.isBundleHideableAppleHost(bundle),
                      !unhideableKeys.contains(id.sectionKey),
                      !bundlelessHosts.contains(bundle)
                else { return nil }
                return bundle
            }
        )
    }

    /// A third-party item whose app the user gave a launcher.
    func hasAppLauncher(for id: ItemID) -> Bool {
        guard let bundle = id.bundleID, !PelmetBundle.ownIDs.contains(bundle) else { return false }
        return settings.extraItems.contains { $0.kind == .appLauncher && $0.bundleID == bundle }
    }

    /// Adds a Pelmet launcher for an app, one per bundle. `section` pre-assigns
    /// it (the editor's "Add a launcher" puts it where the user put the icon it
    /// replaces); nil routes it like any new menu bar icon — it is one.
    @discardableResult
    func addAppLauncher(bundleID: String, name: String, in section: PelmetCore.Section? = nil) -> Bool {
        guard !settings.extraItems.contains(where: { $0.kind == .appLauncher && $0.bundleID == bundleID })
        else { return false }
        let spec = ExtraItemSpec(kind: .appLauncher, bundleID: bundleID, appName: name)
        addExtra(spec, in: section ?? settings.sectionModel.newItemsDestination)
        settingsChanged()
        return true
    }

    /// The one way to add a Pelmet item: the spec AND its model slot
    /// together (`SectionModel.enroll`). `section` nil keeps the model's
    /// word for the key — visible by default. Callers still call
    /// `settingsChanged()`; the boot migration runs before it exists.
    func addExtra(_ spec: ExtraItemSpec, in section: PelmetCore.Section? = nil) {
        settings.extraItems.append(spec)
        let key = ExtrasManager.itemID(for: spec).sectionKey
        settings.sectionModel.enroll(key, in: section)
        PelmetLog.log("extras: add \(spec.itemTitle) → \(settings.sectionModel.section(of: key))")
        settings.save()
        retireAppleTwin(of: spec.kind)
    }

    /// The singleton kinds' toggle going off. Siri and Time Machine also
    /// hand Apple's icon back.
    func removeExtras(of kind: ExtraKind) {
        settings.extraItems.removeAll { $0.kind == kind }
        restoreAppleTwin(of: kind)
    }

    /// The pinned SystemUIServer tile's one action: turn on whichever of
    /// Pelmet's Siri and Time Machine is still off. Each `addExtra` retires
    /// Apple's twin, so once both are on SystemUIServer has no extras left
    /// and the tile that offered this goes away on its own.
    func useAppleExtraReplacements() {
        let missing = missingAppleReplacements
        guard !missing.isEmpty else { return }
        for kind in missing { addExtra(ExtraItemSpec(kind: kind)) }
        settingsChanged()
    }

    /// Which of Apple's pinned pair Pelmet has not replaced yet — what the
    /// pinned card offers, and what its copy names.
    var missingAppleReplacements: [ExtraKind] {
        let kinds = Set(settings.extraItems.map(\.kind))
        return [ExtraKind.siri, .timeMachine].filter { !kinds.contains($0) }
    }

    /// Siri and Time Machine: Apple's own icon switches off in System
    /// Settings the moment Pelmet's switches on (otherwise the bar shows
    /// two), and comes back when Pelmet's goes off — only if Pelmet was the
    /// one that switched it off. Nothing runs at launch: once off, the
    /// System Settings switch stays off on its own, and a user who ticks it
    /// back by hand is not fought.
    private func retireAppleTwin(of kind: ExtraKind) {
        guard let twin = AppleMenuExtra(kind), twin.isShown else { return }
        guard twin.setShown(false) else { return }
        UserDefaults.standard.set(true, forKey: twin.restoreKey)
        // SystemUIServer tears the icon down over a few hundred ms, so the
        // walk its own settings change triggers still sees it and the editor
        // kept showing a tile for an icon already gone. Re-read until it is,
        // rather than once on a fixed delay — a single late look made the
        // tile linger for the whole delay even though the icon went in ~300ms.
        Task {
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(250))
                let snap = await engine.snapshot()
                updateSnapshot(snap)
                let stillThere = snap.items.contains {
                    $0.id.bundleID == PelmetBundle.systemUIServerID && $0.frame != nil
                }
                if !stillThere { return }
            }
        }
    }

    /// SystemUIServer's slot once BOTH its icons are Pelmet's. Nothing else
    /// prunes it: the editor draws a tile for any stored key whose process
    /// runs, the order-slot repair only touches Pelmet's own extras, and
    /// SystemUIServer never quits — so the pinned tile outlived the icons it
    /// stood for (2026-09-16). Guarded on both replacements being on, so a
    /// half-replaced pair keeps the tile the remaining icon still needs.
    /// Cheap no-op once the slot is gone, which is the steady state.
    private func pruneRetiredAppleHostSlot(_ snap: EngineSnapshot) {
        let key = ItemID(rawValue: "bundle:\(PelmetBundle.systemUIServerID)")
        guard settings.sectionModel.assignments[key] != nil
                || settings.sectionModel.order.values.contains(where: { $0.contains(key) })
        else { return }
        let kinds = Set(settings.extraItems.map(\.kind))
        guard kinds.contains(.siri), kinds.contains(.timeMachine) else { return }
        guard !snap.items.contains(where: { $0.id.bundleID == PelmetBundle.systemUIServerID })
        else { return }
        forgetRetiredHost(PelmetBundle.systemUIServerID)
    }

    /// Where the host sat before Pelmet retired it, so turning the Pelmet
    /// items back off puts the returning icons where the user had them
    /// rather than treating them as newcomers.
    private static let retiredSlotKey = "pelmet.appleExtra.systemuiserver.slot"

    private func forgetRetiredHost(_ bundle: String) {
        let key = ItemID(rawValue: "bundle:\(bundle)")
        var slot: [String: Any] = [:]
        // `.visible` is the absence of an assignment, so record the section
        // that way round too — an empty section means visible.
        if let section = settings.sectionModel.assignments[key] {
            slot["section"] = section.rawValue
        }
        for (section, order) in settings.sectionModel.order {
            if let index = order.firstIndex(of: key) {
                slot["orderSection"] = section.rawValue
                slot["index"] = index
                break
            }
        }
        var changed = settings.sectionModel.assignments.removeValue(forKey: key) != nil
        for section in settings.sectionModel.order.keys {
            let before = settings.sectionModel.order[section]?.count
            settings.sectionModel.order[section]?.removeAll { $0 == key }
            if settings.sectionModel.order[section]?.count != before { changed = true }
        }
        lastSeenAt.removeValue(forKey: key)
        guard changed else { return }
        UserDefaults.standard.set(slot, forKey: Self.retiredSlotKey)
        PelmetLog.log("apple extras: dropped dead slot \(key.rawValue) (remembered \(slot))")
        settings.save()
    }

    /// Puts the host back where it was before Pelmet retired it. Runs the
    /// moment a Pelmet replacement is switched off, before the returning
    /// icon re-registers, so `registerNewItems` finds it already placed and
    /// routes nothing.
    private func restoreRetiredHostSlot() {
        guard let slot = UserDefaults.standard.dictionary(forKey: Self.retiredSlotKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.retiredSlotKey)
        let key = ItemID(rawValue: "bundle:\(PelmetBundle.systemUIServerID)")
        if let raw = slot["section"] as? String, let section = PelmetCore.Section(rawValue: raw) {
            settings.sectionModel.assignments[key] = section
        }
        if let raw = slot["orderSection"] as? String,
           let section = PelmetCore.Section(rawValue: raw) {
            var order = settings.sectionModel.order[section] ?? []
            order.removeAll { $0 == key }
            let index = min(max(slot["index"] as? Int ?? order.count, 0), order.count)
            order.insert(key, at: index)
            settings.sectionModel.order[section] = order
        }
        PelmetLog.log("apple extras: restored slot \(key.rawValue) → \(settings.sectionModel.section(of: key))")
        settings.save()
    }

    private func restoreAppleTwin(of kind: ExtraKind) {
        guard let twin = AppleMenuExtra(kind), UserDefaults.standard.bool(forKey: twin.restoreKey) else { return }
        UserDefaults.standard.removeObject(forKey: twin.restoreKey)
        restoreRetiredHostSlot()
        twin.setShown(true)
    }

    /// A move asked for outside the editor (the command bar). Membership
    /// alone leaves the icon where it sits, left of the chevron for a newly
    /// visible one (2026-10-04), so it is drawn at the chevron side of its
    /// new section and applied at once. Edits the editor already holds stay
    /// the person's to apply: then the move only joins them.
    func moveItemNow(_ id: ItemID, to section: PelmetCore.Section, quiet: Bool = false) {
        let before = section == .visible ? editorItems(in: .visible).first { $0.id != id }?.id : nil
        moveItemNow(id, to: section, before: before, quiet: quiet)
    }

    /// The same move with a place in its section: in front of `before` (nil is
    /// the end, nearest the chevron for Hidden and Always Hidden). A drop from
    /// the panel lands where it was aimed (reorder in the panel, 2026-10-12).
    /// `quiet`: a drop on the open panel, whose Apply leaves the panel up and
    /// the bar under its cover (`applyOrderEdits`).
    func moveItemNow(_ id: ItemID, to section: PelmetCore.Section, before: ItemID?, quiet: Bool = false) {
        let othersPending = applyPending
        let accepted = !applying
        moveItem(id, to: section, before: before)
        if accepted { notePanelOrder(of: id, in: section) }
        guard !othersPending else {
            PelmetLog.log("editor: move of \(id.rawValue) joins pending edits, not applied")
            return
        }
        applyOrderEdits(quiet: quiet)
    }

    /// The panel draws a section in the order the bar had at the last reveal
    /// (`lastDrawnOrder`). A move filed from it would show at the end until
    /// the next reveal reads the bar again, so the order just drawn is kept
    /// ahead of the Apply that lays it down.
    private func notePanelOrder(of id: ItemID, in section: PelmetCore.Section) {
        let key = id.sectionKey
        for drawn in lastDrawnOrder.keys { lastDrawnOrder[drawn]?.removeAll { $0 == key } }
        if section != .visible, let order = settings.sectionModel.order[section] { lastDrawnOrder[section] = order }
    }

    /// A pass laid these sections' drawing down: the panel draws them in that
    /// order until the next reveal reads the bar again. The editor's Apply
    /// left the panel on the order before it (Sconce, 2026-10-12).
    private func noteAppliedOrder(of sections: some Sequence<PelmetCore.Section>) {
        for section in sections where section != .visible {
            guard let order = settings.sectionModel.order[section] else { continue }
            let moved = Set(order)
            for drawn in lastDrawnOrder.keys where drawn != section { lastDrawnOrder[drawn]?.removeAll { moved.contains($0) } }
            lastDrawnOrder[section] = order
        }
    }

    /// The icon a tile dropped in front of `neighbour` is filed before. A
    /// break between them is a separator, and the tile goes in front of it:
    /// the first of the run of separators before the neighbour (the order,
    /// less the tile itself, may hold several where the panel draws one).
    func dropAnchor(before neighbour: PanelNeighbour, in section: PelmetCore.Section, moving id: ItemID) -> ItemID? {
        guard neighbour.afterBreak else { return neighbour.item }
        let key = id.sectionKey
        let order = (settings.orderEdits.order[section] ?? barBasedOrder(in: section, model: settings.sectionModel))
            .filter { $0 != key }
        // Last before a trailing break: before the separators that close the
        // section, not appended after them.
        guard let item = neighbour.item else {
            var index = order.endIndex
            while index > 0, order[index - 1].isPelmetSeparator { index -= 1 }
            return index < order.endIndex ? order[index] : nil
        }
        guard var index = order.firstIndex(of: item.sectionKey) else { return item }
        var anchor = item
        while index > 0, order[index - 1].isPelmetSeparator {
            index -= 1
            anchor = order[index]
        }
        return anchor
    }

    /// A ⌘-drag from the bar let go on the open panel (`BarDragRedirect`):
    /// the icon went back to its slot, so it is the one under where the drag
    /// began (`start`, screen points), filed in `section` like a tile drop.
    func barDropOnPanel(_ known: ItemID?, at start: NSPoint, bundle: String?, section: PelmetCore.Section) {
        Task { @MainActor in
            // The icon read at the drag's start, if it is the grabbed app's;
            // else the bar as it is now.
            let found: ItemID?
            if let known, bundle == nil || known.bundleID == bundle {
                found = known
            } else {
                found = Self.barItem(at: start, bundle: bundle, in: await engine.snapshot().items)
            }
            guard let id = found, MenuBarPolicy.isZoneAdoptable(id, pelmetBundleID: PelmetBundle.mainID) else {
                PelmetLog.log("panel: bar drop found no movable icon at x=\(Int(start.x)) (\(found?.rawValue ?? "none"))")
                return
            }
            guard settings.sectionModel.section(of: id) != section else {
                PelmetLog.log("panel: bar drop \(id.rawValue) already in \(section.rawValue)")
                return
            }
            PelmetLog.log("panel: bar drop \(id.rawValue) → \(section.rawValue)")
            moveItemNow(id, to: section, quiet: true)
        }
    }

    /// The bar icon under `point` (screen points), the grabbed app's first:
    /// what a ⌘-drag that began there is carrying. An app with one icon is
    /// that icon wherever the snapshot saw it: positions go stale after a
    /// move (a neighbour was picked, 2026-10-12).
    static func barItem(at point: NSPoint, bundle: String?, in items: [ObservedItem]) -> ItemID? {
        if let bundle {
            let own = items.filter { $0.id.bundleID == bundle }
            if own.count == 1 { return own[0].id }
        }
        // AX frames: top-left origin.
        let ax = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        return items
            .compactMap { item -> (id: ItemID, distance: CGFloat)? in
                guard let frame = item.frame, frame.insetBy(dx: -8, dy: -8).contains(ax) else { return nil }
                let grabbed = bundle.map { item.id.bundleID == $0 } ?? false
                return (item.id, abs(frame.midX - ax.x) - (grabbed ? 10_000 : 0))
            }
            .min { $0.distance < $1.distance }?.id
    }

    func moveItem(_ id: ItemID, to section: PelmetCore.Section, before beforeID: ItemID?) {
        // A drop that lands while a pass runs would be cleared with the
        // pass's own edits on success; the editor is inert meanwhile, this
        // is the backstop for a drop already in flight.
        guard !applying else {
            PelmetLog.log("editor: drop of \(id.rawValue) ignored during apply")
            return
        }
        // The model keys on canonical IDs; `id` arrives as a real bar item
        // (drag payload) and may be any title-variant of its bundle.
        let key = id.sectionKey
        var model = settings.sectionModel
        // Remember where it came from for Discard; drawn back where it
        // started, there is nothing to put back.
        let previous = model.section(of: id)
        for touched in Set([previous, section]) where settings.orderEdits.previousOrder[touched] == nil {
            settings.orderEdits.previousOrder[touched] = barBasedOrder(in: touched, model: model)
        }
        if previous != section {
            if let origin = settings.orderEdits.previousSection[key] {
                if origin == section { settings.orderEdits.previousSection.removeValue(forKey: key) }
            } else {
                settings.orderEdits.previousSection[key] = previous
            }
        }
        if section == .visible {
            model.assignments.removeValue(forKey: key)
        } else {
            model.assignments[key] = section
        }
        for sectionKey in model.order.keys {
            model.order[sectionKey]?.removeAll { $0 == key }
        }
        // A drawing already pending is the user's; otherwise the drop
        // starts from the bar's order, so it counts as one move.
        var order = settings.orderEdits.order[section]
            ?? barBasedOrder(in: section, model: settings.sectionModel)
        order.removeAll { $0 == key }
        var index = beforeID.flatMap { order.firstIndex(of: $0.sectionKey) } ?? order.endIndex
        // Visible ends in the run macOS keeps at the bar's end (Control
        // Center, the clock): Apply lands an icon before it whatever the
        // drawing says (`MovePlan`, trailing pinned), so the drawing says so
        // too. "Move to Visible" drew it after the clock, a clean pass then
        // cleared the edit, and the editor kept it there while the bar had
        // it before Control Center (live test, 2026-10-13).
        if section == .visible, !isImmovable(key) {
            let pinnedTail = order.reversed().prefix { isImmovable($0) || ApplyPass.isProtectedSystemItem($0) }.count
            index = min(index, order.count - pinnedTail)
        }
        order.insert(key, at: index)
        model.order[section] = order
        settings.sectionModel = model
        // The drop is a drawing, the bar moves at Apply. A between-section
        // drop changes membership now and the destination's drawn order is
        // what Apply will lay down, across the chevron too.
        // The key leaves every other section's edit too: a stale entry
        // put Siri in two tidy runs at once and MovePlan trapped on the
        // duplicate key (crash 2026-09-20 17:29).
        for edited in settings.orderEdits.order.keys where edited != section {
            settings.orderEdits.order[edited]?.removeAll { $0 == key }
        }
        settings.orderEdits.order[section] = order
        settings.orderEdits.dropped.insert(key)
        pruneSettledOrderEdits()
        applyReport = nil
        settings.save()
        // A separator's host follows its drawn section at Apply
        // (`SeparatorManager.hostedSection`); `sync` keeps the specs current.
        separators?.sync(with: settings.separators)
        PelmetLog.log("editor: move \(id.rawValue) → \(section) before=\(beforeID?.rawValue ?? "end")")
        // Extras visibility applies via the engine's reflow companion during
        // the converge below — same reflow, same motion as everything else.
        Task {
            await engine.setModel(model)
            // The plist hint seeds slots for FUTURE fresh registrations
            // (app relaunches, brand-new items); live items move at Apply.
            await engine.writeOrderHint()
        }
    }

    /// An own item that just (re-)entered a REVEALED bar sits at the agent's
    /// slot, not the model's — a launcher whose app launched mid-reveal
    /// surfaced at the end of Always Hidden (ChatGPT Classic, 2026-09-09).
    /// Place it now, same beat as a freshly added extra.
    /// Own extras that entered the bar while their section was concealed:
    /// no neighbour to measure, so they wait for the next reveal that shows
    /// their section (`onRevealSettled`) and go through the door then.
    private var ownItemsAwaitingReveal: Set<ItemID> = []
    /// Own items that already got their one retry after a failed pass.
    private var ownItemsRetried: Set<ItemID> = []
    /// Passes that found the item not laid out yet, by item.
    private var ownItemMisses: [ItemID: Int] = [:]
    /// When the boot adoption saw every own item; nil until then.
    private var ownItemsAdoptedAt: ContinuousClock.Instant?

    /// An own extra entering a concealed section.
    func placeOwnItemAtNextReveal(_ id: ItemID) {
        ownItemsAwaitingReveal.insert(id)
    }

    /// An extra joined the bar: the engine owes it a walk at rest, the one
    /// the Apply count waits on (`unreadNow`). Shown outside a swap, none
    /// came, and "Apply (1)" stayed until the next transition (review,
    /// 2026-10-13). Background, coalesced; not before the engine runs (the
    /// launch walks for itself).
    func ownItemShown() {
        guard engineStarted else { return }
        Task { await engine.ownItemShown() }
    }

    /// Deactivation edge: an indicator that left layout has nothing to
    /// place — the reveal-settle entry goes, and so does a pass still in
    /// its lead time (the media control showed and hid in the same boot
    /// apply and was dragged 600ms later to x=-1, 2026-09-21 07:05).
    func cancelOwnItemPlacement(_ id: ItemID) {
        ownItemsAwaitingReveal.remove(id)
        ownItemPassLeads[id]?.cancel()
        ownItemPassLeads.removeValue(forKey: id)
    }

    /// One-item passes waiting out their lead time, by item.
    private var ownItemPassLeads: [ItemID: Task<Void, Never>] = [:]

    private func placeOwnItemsAwaitingReveal() {
        // A pass reveals too; leave the queue for a user reveal then.
        guard !applying, !ownItemsAwaitingReveal.isEmpty else { return }
        let revealed = currentRevealedSections
        // Visible is on screen at every reveal: an item that missed its pass
        // there goes through the door at the next one too.
        let due = ownItemsAwaitingReveal.filter {
            let section = settings.sectionModel.section(of: $0)
            return section == .visible || revealed.contains(section)
        }
        guard !due.isEmpty else { return }
        ownItemsAwaitingReveal.subtract(due)
        Task {
            for id in due { await placeOwnItemNow(id) }
        }
    }

    func placeOwnItemSoon(_ id: ItemID, after lead: Duration = AppTiming.newExtraPlacementDelay) {
        ownItemPassLeads[id]?.cancel()
        ownItemPassLeads[id] = Task { [weak self] in
            try? await Task.sleep(for: lead)
            guard !Task.isCancelled, let self else { return }
            ownItemPassLeads.removeValue(forKey: id)
            await placeOwnItemNow(id)
        }
    }

    /// One own item through the Apply door (`ApplyPass.Scope.
    /// ownItem`). Never overlaps a running pass; a whole-bar pass covers it.
    private func placeOwnItemNow(_ id: ItemID) async {
        guard !applying else { return placeOwnItemAfterPassInFlight(id) }
        // Boot: measure only once the bar has finished attaching
        // (`barAttachesAt`); before the adoption, a full lead from now.
        let due = barAttachesAt ?? ContinuousClock.now + AppTiming.bootOwnItemLead
        if ContinuousClock.now < due {
            PelmetLog.log("apply: own \(id.rawValue) waits for the boot lead")
            try? await Task.sleep(until: due, clock: .continuous)
            guard !applying else { return placeOwnItemAfterPassInFlight(id) }
        }
        // Checked before the layout test: a concealed section ghosts its
        // extra at once, which is not the flap below (Siri toggle, 2026-09-21).
        // The edge may have fired on a revealed bar that concealed before
        // the pass ran (a timer started 40ms before the hover delay
        // expired, 2026-09-20: "no live neighbour to aim at"). Off screen
        // there is nothing to measure; wait for the next reveal instead.
        let section = settings.sectionModel.section(of: id)
        let concealed = section != .visible && !currentRevealedSections.contains(section)
        guard !concealed else {
            PelmetLog.log("apply: own \(id.rawValue) section concealed — waits for a reveal")
            ownItemsAwaitingReveal.insert(id)
            return
        }
        // An extra that left layout again while its section is on screen
        // (a show/hide flap inside one apply) has no frame to move; the next
        // entry edge queues it anew.
        if let extras, extras.managedItemIDs.contains(where: { $0.sectionKey == id.sectionKey }), !extras.isShowing(id) {
            PelmetLog.log("apply: own \(id.rawValue) left layout before its pass — nothing to place")
            return
        }
        applying = true
        defer { applying = false }
        let report = await ApplyPass.run(appState: self, scope: .ownItem(id))
        PelmetLog.log("apply: own \(id.rawValue) applied=\(report.applied.count) failed=\(report.failed.count) skipped=\(report.skipped.count)")
        if !report.applied.isEmpty { await engine.writeOrderHint() }
        // Not laid out yet: a brand-new item reaches the bar's AX tree on
        // the agent's beat, and a shortcut added on a concealed bar was not
        // there 640ms later, so it stayed left of the chevron in Visible
        // (2026-09-28). One more pass after a longer wait, then the next
        // reveal settle, then it is Apply's.
        let missed = report.skipped.contains { $0.item == id.sectionKey && $0.why == .notOnScreen }
        if missed {
            let misses = (ownItemMisses[id] ?? 0) + 1
            ownItemMisses[id] = misses
            switch misses {
            case 1:
                PelmetLog.log("apply: own \(id.rawValue) not on screen yet — one more pass shortly")
                placeOwnItemSoon(id, after: AppTiming.ownItemRetryDelay)
            case 2:
                PelmetLog.log("apply: own \(id.rawValue) still not on screen — waits for a reveal")
                ownItemsAwaitingReveal.insert(id)
            default:
                PelmetLog.log("apply: own \(id.rawValue) never on screen — left to Apply")
                ownItemMisses.removeValue(forKey: id)
            }
        // A failed move on a concealable section gets one more try at the
        // next reveal settle (the bar may have concealed mid-pass).
        } else if !report.failed.isEmpty, section != .visible, ownItemsRetried.insert(id).inserted {
            ownItemsAwaitingReveal.insert(id)
        } else if !report.applied.isEmpty {
            ownItemsRetried.remove(id)
            ownItemMisses.removeValue(forKey: id)
        }
    }

    /// Another pass holds the door (two own items' retries due together, a
    /// user's Apply). Dropped, the Live Activities item kept the agent's
    /// slot behind Media's retry and Apply (1) stayed (Gab, 2026-10-29):
    /// it goes again once that pass is done.
    private func placeOwnItemAfterPassInFlight(_ id: ItemID) {
        PelmetLog.log("apply: own \(id.rawValue) waits for the pass in flight")
        placeOwnItemSoon(id, after: AppTiming.ownItemRetryDelay)
    }

    /// Pelmet's chevron item in a snapshot — the visible/hidden boundary marker
    /// (never an extra or separator).
    func pelmetChevronItem(in snap: EngineSnapshot) -> ObservedItem? {
        let pelmetBundle = PelmetBundle.mainID
        let copies = snap.items.filter {
            MenuBarPolicy.isChevronID($0.id, pelmetBundleID: pelmetBundle)
        }
        // The chevron registers once per display; only the main-band copy
        // is a boundary anything can be measured against.
        let primaryMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        return copies.first(where: {
            $0.frame.map { MenuBarGeometry.isInBand($0) && $0.midX > 0 && $0.midX < primaryMaxX } == true
        }) ?? copies.first
    }

    /// A section's members in the bar's order — the baseline every edit
    /// starts from. A drawing that drifted from the bar without an edit is
    /// harmless until an edit makes the plan honour it, and then one drop
    /// read "Apply (2)" (2026-09-21). Members the bar has no frame for keep
    /// their drawn slot (`BarAdoption.refill`).
    func barBasedOrder(in section: PelmetCore.Section, model: SectionModel) -> [ItemID] {
        let members = model.order[section] ?? currentOrder(in: section)
        guard let snapshot else { return members }
        let onBar = ApplyPass.barOrder(ApplyPass.rememberedFrames(snapshot, appState: self))
        return BarAdoption.refill(members, inBarOrder: onBar)
    }

    /// The on-screen left-to-right order of a section right now (fallback when
    /// no explicit order exists yet).
    func currentOrder(in section: PelmetCore.Section) -> [ItemID] {
        // Order arrays hold canonical keys; tiles carry real item IDs.
        editorItems(in: section).map(\.id.sectionKey)
    }

    // MARK: - Apply (sets core, docs/CORE-SETS.md M1)

    /// One pass at a time; the button reads these.
    private(set) var applying = false
    private(set) var applyReport: ApplyReport?

    /// The editor owns the order (vault plan "Dimble editor owns the bar
    /// order", 2026-10-20): every section's stored order is what the bar
    /// should read. A drop writes its drawing there at once, so a pending
    /// drawing is in it too.
    var editorOrderTarget: OrderEdits {
        var target = settings.orderEdits
        target.order = settings.sectionModel.order
        return target
    }

    /// Moves the bar needs to match the editor as it stands: every
    /// section's stored order (`editorOrderTarget`), so drawn edits, drift
    /// and any icon on the wrong side of the chevron (0 with nothing on
    /// screen to move).
    var pendingMoveCount: Int {
        guard let snapshot else { return 0 }
        // Dropped icons the plan cannot see count too: behind the « (the
        // pass expands it) or concealed with their section (the pass reveals
        // it). The rules are `ApplyCount`'s. The pass still expands for every
        // drawn icon behind the « (`ApplyPass.trappedEdited`).
        let plan = ApplyPass.plan(for: self, snapshot: snapshot, remembered: true)
        let moves = plan.moves
        let count = ApplyCount.count(
            plan, edits: settings.orderEdits, trapped: ApplyPass.trapped(snapshot, appState: self),
            drawn: drawnNow(in: snapshot), concealed: concealedNow(in: snapshot), unread: unreadNow(in: snapshot)
        )
        // Logged on change only (the button reads this every render): which
        // move pads the count when the drop read "Apply (2)" (2026-09-21).
        // The floor (`ApplyCount`: a drop the plan can't see yet) is the rest.
        let floor = count.total - moves.count - count.trapped.count - count.concealed.count
        let line = "\(moves.count) move(s) + \(count.trapped.count) trapped + \(count.concealed.count) concealed"
            + (floor > 0 ? " + \(floor) floor" : "") + " = \(count.total) — "
            + moves.map { "\($0.item.rawValue) after=\($0.after?.rawValue ?? "-") before=\($0.before?.rawValue ?? "-")" }.joined(separator: "; ")
            + " | trapped=" + count.trapped.map(\.rawValue).sorted().joined(separator: ",")
            + " concealed=" + count.concealed.map(\.rawValue).sorted().joined(separator: ",")
            // Why the plan could not place each: a drop into a concealed
            // Hidden kept no place although its frame was remembered
            // (Vorssaint, 2026-10-13 22:43:06).
            + count.concealed.map { key in
                let listed = snapshot.items.first { $0.id.sectionKey == key }
                let inSet = snapshot.concealed.contains { $0.sectionKey == key }
                return " [\(key.rawValue) set=\(inSet) listed=\(listed.map { $0.frame.map { "\(Int($0.minX))" } ?? "noframe" } ?? "no")"
                    + " remembered=\(rememberedFrames[key].map { "\(Int($0.minX))" } ?? "none")]"
            }.sorted().joined()
        if line != lastPendingLine {
            lastPendingLine = line
            PelmetLog.log("apply: pending \(line)")
        }
        return count.total
    }
    private var lastPendingLine = ""

    /// The number on the Apply button: `pendingMoveCount` through
    /// `ApplyCountHold`. The raw count is read off asynchronous snapshots and
    /// dipped to 0 for 100–550ms on three paths in three rounds (a stale
    /// walk at the drop, an own extra's show, a reveal: live test,
    /// 2026-10-13 21:13:26), so a drop to 0 with edits pending is held here,
    /// once for every path, rather than patched per path. Read from the
    /// button's body: the hold only matters where the number is drawn, and
    /// the plan is not read on every snapshot while Settings is closed.
    var applyButtonCount: Int {
        _ = applyCountTick
        return feedApplyCount(now: .now)
    }
    /// Bumped when a held 0 is due, so the button reads the count again.
    private var applyCountTick = 0
    @ObservationIgnored private var applyCountHold = ApplyCountHold(hold: AppTiming.applyCountZeroHold)
    @ObservationIgnored private var applyCountCommit: Task<Void, Never>?
    @ObservationIgnored private var applyCountCommitDue: ContinuousClock.Instant?

    private func feedApplyCount(now: ContinuousClock.Instant) -> Int {
        let wasHolding = applyCountHold.isHolding
        let shown = applyCountHold.feed(pendingMoveCount, editsPending: !settings.orderEdits.isEmpty, now: now)
        if applyCountHold.isHolding != wasHolding {
            PelmetLog.log(applyCountHold.isHolding
                ? "apply: button holds (\(shown)) over a count of 0"
                : "apply: button hold over — shows \(shown == 0 ? "Apply" : "Apply (\(shown))")")
        }
        // One read at the hold's end, for the button to redraw from.
        guard applyCountHold.due != applyCountCommitDue else { return shown }
        applyCountCommit?.cancel()
        applyCountCommitDue = applyCountHold.due
        applyCountCommit = applyCountHold.due.map { due in
            Task { [weak self] in
                try? await Task.sleep(until: due, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                self.applyCountCommit = nil
                self.applyCountCommitDue = nil
                // Shown only if it still reads 0 now (`feed`).
                _ = self.feedApplyCount(now: max(ContinuousClock.now, due))
                self.applyCountTick &+= 1
            }
        }
        return shown
    }

    /// The button left the screen (another tab, Settings closed): the number
    /// it held is no one's. Kept, it came back as the old "Apply (1)" for
    /// 300ms after the grouper had placed the icon off screen (review,
    /// 2026-10-13).
    func resetApplyCountHold() {
        applyCountCommit?.cancel()
        applyCountCommit = nil
        applyCountCommitDue = nil
        applyCountHold = ApplyCountHold(hold: AppTiming.applyCountZeroHold)
    }

    /// Last primary-band frame per item, kept across conceals so the Apply
    /// count can judge a concealed icon's side without a reveal
    /// (ApplyPass.rememberedFrames). Refreshed from every snapshot, and
    /// after a pass's drags (`rereadFramesAfterPass`).
    private(set) var frameMemory = FrameMemory()
    var rememberedFrames: [ItemID: CGRect] { frameMemory.frames }
    var rememberedChevronMidX: [ItemID: CGFloat] { frameMemory.chevronMidX }
    /// Own items (canonical keys) the last walk that saw them live found
    /// behind the «: no frame is remembered there, so once concealed they
    /// read as let go and a reorder of only that separator cleared at once
    /// (`OrderEditSettle`).
    @ObservationIgnored private var ownItemsBehindOverflow: Set<ItemID> = []
    /// When the latest walk at rest handed to `updateSnapshot` was taken,
    /// including one dropped there as reading the same as the snapshot.
    /// Observed: that walk is what turns an extra's show read, and the
    /// Apply count reads it (`unreadNow`).
    private var lastRestWalkAt: Date?

    /// Apply has something to do: a drawing not yet applied, or the bar
    /// disagreeing with the sections.
    var applyPending: Bool {
        !settings.orderEdits.isEmpty || pendingMoveCount > 0 || (separators?.needsRehost ?? false)
    }

    /// Apply pass: separators drawn in another section move host now.
    func rehostSeparatorsForApply() -> Bool { separators?.rehostToModel() ?? false }
    /// A separator is hosted for another section than the editor's: only
    /// Apply re-hosts it, so the order keeper leaves separators alone.
    var separatorsNeedRehost: Bool { separators?.needsRehost ?? false }

    /// The primary bar as live frames read it, for what writes the stored
    /// order (M4, M5). Never a remembered frame: a stale or phantom one
    /// written there is kept for good, and the keeper drags the bar to it
    /// (review, 2026-10-20). A walk at rest only. Nothing behind the «,
    /// nothing out on its own beside the chevron, nothing just concealed
    /// (still listed on a phantom frame), no own extra leaving a concealed
    /// section.
    private func liveBarForOrder(_ snap: EngineSnapshot) -> [ItemID] {
        guard snap.itemsAtRest else { return [] }
        let roster = settings.sectionModel.roster
        let revealed = revealedSectionsForExtras
        let away = ApplyPass.trapped(snap, appState: self)
            .union(snap.shownAlone.map(\.sectionKey))
            .union(snap.concealed.map(\.sectionKey))
        let frames = ApplyPass.primaryFrames(snap, appState: self).filter { key, _ in
            guard !away.contains(key) else { return false }
            guard MenuBarPolicy.isPelmetExtraID(key) else { return true }
            let section = roster.section(of: key)
            return section == .visible || revealed.contains(section)
        }
        return ApplyPass.barOrder(frames)
    }

    /// M4 of the editor-owns-order plan: an icon its section's stored order
    /// doesn't list yet (a new app's) is listed where it sits among live
    /// neighbours, so the order keeper never drags a newcomer. One that is
    /// concealed waits for a reveal (the keeper leaves unlisted icons
    /// alone meanwhile). Strays wait for the grouper to bring them over,
    /// and own items are enrolled where they are made.
    @discardableResult
    func slotUnlistedIcons(_ snap: EngineSnapshot, skipping strays: Set<ItemID>) -> [ItemID] {
        let bar = liveBarForOrder(snap)
        let exempt = Set(bar.filter { id in
            strays.contains(id) || !MenuBarPolicy.isSectionManageable(id)
                || id.bundleID.map(PelmetBundle.ownIDs.contains) == true
        })
        var model = settings.sectionModel
        let chevron = pelmetChevronItem(in: snap)?.id.sectionKey
        let slotted = model.slotUnlisted(bar: bar, chevron: chevron, exempt: exempt)
        guard !slotted.isEmpty else { return [] }
        settings.sectionModel = model
        settings.save()
        PelmetLog.log("order: slotted [\(slotted.map(\.rawValue).joined(separator: ", "))] where they landed")
        return slotted
    }

    private static let seededOrderKey = "pelmet.seededOrderFromBar"
    private static let seedPassLimit = 2
    private var seedPasses = 0

    /// Sections whose stored order hasn't been taken from the bar since the
    /// editor came to own the order (M5).
    var unseededOrderSections: Set<PelmetCore.Section> {
        let stored = UserDefaults.standard.stringArray(forKey: Self.seededOrderKey) ?? []
        return Set(PelmetCore.Section.allCases).subtracting(stored.compactMap(PelmetCore.Section.init(rawValue:)))
    }

    /// M5 of the editor-owns-order plan: until this update the bar's order
    /// was the truth and the stored one could lag it, so the first drift
    /// the keeper sees is the bar the user had, not drift. The keeper's
    /// seed pass (`ApplyPass.Scope.seedOrder`) reveals the bar and hands
    /// the live snapshot here: each section's stored order takes the bar's
    /// (`foldBarOrder`), once. Every section seen is marked, drifted or
    /// not, or one that matched at the update would lose its order to its
    /// first real drift days later. A section the read missed (a walk not
    /// at rest, a member still concealed: the reveal didn't take) waits for
    /// the next seed pass, and is marked as it is after `seedPassLimit`
    /// passes in a launch, or every cooldown would reveal the bar again
    /// (review). A section with a drawing waiting for Apply is the user's
    /// target already: marked, not seeded.
    func seedOrderFromBar(_ sections: Set<PelmetCore.Section>, snap: EngineSnapshot) {
        seedPasses += 1
        let bar = liveBarForOrder(snap)
        let roster = settings.sectionModel.roster
        let concealed = Set(snap.concealed.map(\.sectionKey))
        var model = settings.sectionModel
        var changed = false
        var read = Set<PelmetCore.Section>()
        for section in PelmetCore.Section.allCases where sections.contains(section) {
            let hiddenStill = concealed.filter { roster.section(of: $0) == section }.count
            guard snap.itemsAtRest, hiddenStill == 0 else {
                let why = snap.itemsAtRest ? "\(hiddenStill) icon(s) concealed" : "bar not at rest"
                if seedPasses < Self.seedPassLimit {
                    PelmetLog.log("order: \(section.rawValue) not read (\(why)) — seeded at the next look")
                    continue
                }
                PelmetLog.log("order: \(section.rawValue) not read (\(why)) after \(seedPasses) looks — kept as stored")
                read.insert(section)
                continue
            }
            read.insert(section)
            if settings.orderEdits.order[section] != nil {
                PelmetLog.log("order: \(section.rawValue) has a drawing — not seeded")
            } else {
                let folded = model.foldBarOrder(of: section, bar: bar)
                changed = changed || folded
                PelmetLog.log("order: seeded \(section.rawValue) from the bar\(folded ? "" : " (already in order)")")
            }
        }
        let marked = Set(PelmetCore.Section.allCases).subtracting(unseededOrderSections).union(read)
        UserDefaults.standard.set(marked.map(\.rawValue).sorted(), forKey: Self.seededOrderKey)
        if changed {
            settings.sectionModel = model
            settings.save()
        }
    }

    /// The Apply button: reveal what needs measuring, plan, drag each move
    /// through the one shielded door, verify, report. Failed moves keep the
    /// edits pending so the button offers Retry.
    ///
    /// `quiet`: a drop on the open panel started it. The panel stays up and
    /// the bar stays under a cover from before the reveal until it is
    /// concealed again, so none of the pass shows (`holdBarForApply`). Any
    /// other Apply closes the panel and shows the bar, as it always has, and
    /// so does a quiet one that could not hold the bar or did not finish clean.
    func applyOrderEdits(quiet: Bool = false) {
        guard !applying, applyPending else { return }
        applying = true
        applyReport = nil
        PelmetLog.log("apply: starting")
        Task {
            var held: ApplyReport?
            if quiet, panelShowsReveal, isRevealed, panelPresenter.isOpen {
                held = await transitions.holdBarForApply(
                    revealing: [.hidden, .alwaysHidden],
                    run: { await runApplyPass() },
                    lifted: { self.panelPresenter.quietApplyEnded() })
            }
            let report: ApplyReport
            if let held { report = held } else { report = await runApplyPass() }
            applyReport = report
            applying = false
            // The bar is concealed and the panel is open on a clean quiet
            // pass; a failed one ends the way an Apply does, with both away.
            let clean = report.failed.isEmpty && report.skipped.allSatisfy { $0.why != .notOnScreen }
            if (held == nil || !clean), !settingsWindowVisible {
                applyPointerDisplayPolicyAfterDismissal()
            }
        }
    }

    /// The pass and what follows it: the edits it settled, the order hint.
    private func runApplyPass() async -> ApplyReport {
        let report = await ApplyPass.run(appState: self)
        PelmetLog.log("apply: done applied=\(report.applied.count) failed=\(report.failed.count) skipped=\(report.skipped.count)")
        // An edit whose item the pass could not reach (behind the «)
        // is not done either: it stays pending like a failed move.
        let unreachable = report.skipped.filter { $0.why == .notOnScreen }.map(\.item)
        if report.failed.isEmpty, unreachable.isEmpty {
            noteAppliedOrder(of: settings.orderEdits.order.keys)
            settings.orderEdits = OrderEdits()
            settings.save()
        } else if report.failed.isEmpty {
            var edits = settings.orderEdits
            // A landed icon joins the baseline Discard restores for a
            // section still pending (`OrderEdits.land`).
            let bar = snapshot.map { ApplyPass.barOrder(ApplyPass.rememberedFrames($0, appState: self)) } ?? []
            let cleared = edits.settlePartialPass(
                applied: report.applied.map(\.sectionKey), unreachable: unreachable, bar: bar
            )
            noteAppliedOrder(of: cleared)
            settings.orderEdits = edits
            settings.save()
        }
        // Seed future fresh registrations with the order just laid down —
        // after ANY move, not only a clean pass: a Camera moved at 18:35
        // went back to its old slot on relaunch because every later pass
        // failed on another item and never reseeded (2026-09-20).
        if !report.applied.isEmpty {
            await engine.writeOrderHint()
        }
        return report
    }

    // MARK: - Keep sections grouped (docs/CORE-SETS.md, #80)

    /// Why the bar is not at rest, nil when it is: fully concealed, nothing
    /// of Pelmet's or the user's holding it out. The one list every reader
    /// takes its part of, from the inside out: `overflowReadHold` (Pelmet
    /// has icons out or the « open), `barInFlux` (that, or a transition),
    /// and the grouping gate (all of it). A strays pass that started under a
    /// panel the hotkey opened shut it, and one under a hotkey reveal of
    /// Hidden widened it to Always Hidden and then concealed it (2026-10-13).
    var fluxReason: String? {
        if let moving = barMovingReason { return moving }
        if panelPresenter.isOpen { return "panel open" }
        // A reveal the user holds (a hover, the chevron, a shortcut), or
        // icons Show in Menu Bar brought out (`.revealed` with no sections).
        // Not a display set to always show: that reveal never ends, and the
        // pass puts the policy back after it (`applyPointerDisplayPolicy…`).
        // Nor an icon a show rule keeps out (Battery on battery): it can stay
        // out all day, and the pass's reveal puts it back in its slot anyway.
        if case .revealed(_, let reason) = rehide.state, reason != .displayPolicy {
            return itemsInBar.isEmpty ? "the bar is revealed (\(reason))" : "icons out on their own"
        }
        return nil
    }

    /// Pelmet has the bar: a pass (Apply, the quiet Apply under the panel, a
    /// picture pass) or a relay (an item menu, the clock, Camera & mic) has
    /// icons out or the « open, so a walk reads a bar nobody sees; or a Live
    /// Activities lift has let the system's extras and pills in.
    private var overflowReadHold: String? {
        if applying { return "an Apply pass has the bar" }
        if transitions.quietApplyInFlight { return "a quiet Apply has the bar" }
        if transitions.passInFlight { return "a picture pass has the bar" }
        if clockBlinkInFlight || audioVideoRelayActive { return "clock or Camera & mic relay in flight" }
        if press.isRunning { return "item menu relay in flight" }
        if let lift = liftHoldReason { return lift }
        return nil
    }

    /// A Live Activities lift has the bar, or its re-hide is settling (#106):
    /// the extras and pills it lets back are in the bar's order and push
    /// icons behind the «. The order keeper waits on it by name.
    var liftHoldReason: String? { transitions.liftHoldReason }

    private var barMovingReason: String? {
        overflowReadHold ?? (isTransitioning ? "reveal or conceal in progress" : nil)
    }

    /// The bar's frames don't say where the icons sit right now: a pass or a
    /// transition is moving them, a relay has an icon out alone or the «
    /// open. The grouping ledger takes no look then: one under a press
    /// relay's open « read Cardhop as in place and spent the editor drop
    /// that explained it (#81). A picture pass counts: its rounds show
    /// icons alone from behind the « under the cover.
    var barInFlux: Bool { barMovingReason != nil }

    /// An item menu relay is clicking: its clicks on an icon behind an open «
    /// hit-test as empty bar.
    var pressRunning: Bool { press.isRunning }

    /// When the bar has finished attaching at launch: `bootOwnItemLead`
    /// after the own items were adopted (the chevron lands on its neighbours
    /// meanwhile). nil until they are.
    private var barAttachesAt: ContinuousClock.Instant? {
        ownItemsAdoptedAt.map { $0 + AppTiming.bootOwnItemLead }
    }

    /// The bar has attached at launch: frames read now are where the icons sit.
    private var barAttached: Bool {
        barAttachesAt.map { ContinuousClock.now >= $0 } ?? false
    }

    /// Why the automatic grouping pass must not start right now (nil = the
    /// door is open). `transient` gates clear on their own and are re-checked
    /// on the debounce beat; the others wait for the snapshot or roster
    /// change that ends them (overflow, a policy switched off), or for the
    /// wake or unlock `SectionGrouper` listens for. Cheap reads first: the
    /// window-list reads run last, and only on an idle, awake bar.
    func groupingGate() -> (why: String, transient: Bool)? {
        // Boot: the bar is still attaching, as for the own-item passes.
        guard engineStarted, barAttached else { return ("booting", true) }
        guard accessibilityGranted else { return ("no accessibility access", false) }
        // The bar's frames and the pointer are not ours right now, or the
        // user has the bar: grouping runs only from a fully concealed bar.
        if let flux = fluxReason { return (flux, true) }
        if !ownItemPassLeads.isEmpty { return ("own item placement queued", true) }
        if adoptionInFlight || dropAdoptionInFlight { return ("user drag being adopted", true) }
        // Icons behind the native « have phantom frames; Apply reports them.
        if overflowTrappedCount > 0 { return ("bar overflows", false) }
        // Something of the user's is open on screen.
        if grouper.menuIsOpen { return ("menu open", true) }
        if commandBar.isOpen { return ("command bar open", true) }
        if EditorDragSession.anyActive { return ("editor drag in progress", true) }
        if OnboardingController.shared.isPresented { return ("onboarding showing", true) }
        if NSEvent.pressedMouseButtons != 0 { return ("mouse button down", true) }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return ("display asleep", false) }
        if Self.sessionAway { return ("screen locked", false) }
        // The quiet Apply asks of the pointer, asked of the keyboard too:
        // the ⌘-click of a drag makes the icon's app frontmost, and a
        // keystroke then lands in it. A busy user defers the pass instead of
        // starting one that seizes input after Apply's 8s wait.
        if ApplyPass.secondsSinceAnyInput() < AppTiming.applyIdleGap { return ("input active", true) }
        // The editor holds the bar for Apply only, so `.active` is no reason:
        // an editor drop is the main way a stray appears.
        if let reason = bandMonitor?.rehideDeferReason(), reason != .active {
            return ("pointer or drag in the bar: \(reason.rawValue)", true)
        }
        // Another app's open menu (or one ItemPress opened for a concealed
        // item): any pop-up-menu-level window on screen, from any process.
        if let owner = SectionGrouper.popUpMenuOwner() { return ("menu window on screen (\(owner))", true) }
        return nil
    }

    /// The session is locked or switched to another user: drags would go to
    /// the login window.
    private static var sessionAway: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
            || (session[kCGSessionOnConsoleKey as String] as? Bool) == false
    }

    /// One automatic pass (`.strays` for the strays Pelmet can explain,
    /// `.drift` for the keeper's), through the Apply door. nil when an Apply
    /// pass already has the bar. Never touches the button's report. The
    /// drags make the dragged icon's app frontmost (only Settings is
    /// refocused by the pass), so whoever had focus gets it back.
    func runGroupingPass(_ scope: ApplyPass.Scope) async -> ApplyReport? {
        guard scope.isAutomatic, !applying else { return nil }
        applying = true
        // The walk at rest skips its prune while the pass holds the bar
        // (restoreFocus runs up to ~550ms), and it is the only one after a
        // swap: pruned here, a settled drawing never waits for the next
        // transition with Apply lit (review, 2026-10-13).
        defer { applying = false; pruneSettledOrderEdits() }
        let front = NSWorkspace.shared.frontmostApplication
        let report = await ApplyPass.run(appState: self, scope: scope)
        if !report.applied.isEmpty { await engine.writeOrderHint() }
        satisfyDrawnEdits(for: report.applied)
        if let front, !report.abandoned, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            // The processes behind the icons the pass dragged, and Pelmet:
            // the only apps the pass can have brought forward.
            let moved = Set((report.applied + report.failed).map(\.sectionKey))
            var dragged = Set((snapshot?.items ?? []).filter { moved.contains($0.id.sectionKey) && $0.pid > 0 }.map(\.pid))
            dragged.insert(ProcessInfo.processInfo.processIdentifier)
            await restoreFocus(to: front, from: dragged)
        }
        return report
    }

    /// A stray that landed on its side is applied, as after an Apply pass:
    /// Discard has nothing to put back, and a section whose drawing the bar
    /// now matches in full clears (`pruneSettledOrderEdits`), so Apply's
    /// count drops for it. Other pending reorders stay as they are. Every
    /// landing counts, the chevron end too: only drawn-slot ones did, and an
    /// editor move that went to the chevron end kept its `previousSection`
    /// and Apply lit (vorssaint Visible → Hidden, 2026-10-07).
    /// The landed icon joins its section's baseline where the bar has it
    /// (`OrderEdits.land`): Hidden stayed pending on a baseline without
    /// Vorssaint, and Discard drew it last (live test, 2026-10-13).
    private func satisfyDrawnEdits(for landed: [ItemID]) {
        guard !landed.isEmpty else { return }
        var edits = settings.orderEdits
        let bar = snapshot.map { ApplyPass.barOrder(ApplyPass.rememberedFrames($0, appState: self)) } ?? []
        for id in landed { edits.land(id.sectionKey, bar: bar) }
        if edits != settings.orderEdits { settings.orderEdits = edits }
        pruneSettledOrderEdits()
        settings.save()
        PelmetLog.log("group: edit satisfied for [\(landed.map(\.rawValue).joined(separator: ", "))] — Apply has \(pendingMoveCount) left")
    }

    private func restoreFocus(to app: NSRunningApplication, from dragged: Set<pid_t>) async {
        func isFront() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        // The flip lands on the agent's beat.
        try? await Task.sleep(for: .milliseconds(250))
        guard !isFront(), !app.isTerminated else { return }
        // Only a drag's activation is ours to undo: an app the user switched
        // to meanwhile (⌘-Tab within the beat) keeps the focus.
        guard let now = NSWorkspace.shared.frontmostApplication, dragged.contains(now.processIdentifier) else {
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing"
            PelmetLog.log("group: focus left with \(name) — not an app the pass dragged")
            return
        }
        app.activate()
        try? await Task.sleep(for: .milliseconds(150))
        if !isFront() {
            // Cooperative activation can refuse a background app: ask the
            // app itself (public AX, already trusted for the pass).
            AXUIElementSetAttributeValue(
                AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue
            )
            try? await Task.sleep(for: .milliseconds(150))
        }
        PelmetLog.log("group: focus handed back to \(app.localizedName ?? "pid \(app.processIdentifier)") — \(isFront() ? "front" : "not front")")
    }

    /// 0.3.0 upgrade (docs/CORE-SETS.md §Upgrade): a 0.2.x build kept a
    /// per-section order its own placement was still realising; the sets
    /// core moves nothing on its own. Once, at the first snapshot that
    /// frames every item (boot walks the whole bar before the assertion; a
    /// reveal does the same later), each section whose stored drawing
    /// disagrees with the bar becomes a pending edit: Apply reproduces the
    /// old bar, Discard keeps it as it stands. Compared over the icons the
    /// bar frames — an app not running today keeps its drawn slot and is
    /// no edit. A section already mid-edit is left alone.
    private static let orderSeedKey = "pelmet.migratedOrderEditsSeed030"
    private func seedOrderEditsFromStoredOrderIfNeeded(_ snap: EngineSnapshot) {
        guard engineStarted, !UserDefaults.standard.bool(forKey: Self.orderSeedKey) else { return }
        guard !settings.sectionModel.order.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.orderSeedKey)
            return
        }
        let frames = ApplyPass.rememberedFrames(snap, appState: self)
        let known = snap.items.map(\.id.sectionKey) + snap.concealed.map(\.sectionKey)
        guard !known.isEmpty, known.allSatisfy({ frames[$0] != nil }) else { return }
        let bar = ApplyPass.barOrder(frames)
        var edits = settings.orderEdits
        var seeded: [PelmetCore.Section] = []
        for (section, drawn) in settings.sectionModel.order where edits.order[section] == nil {
            let framed = drawn.filter { frames[$0] != nil && settings.sectionModel.section(of: $0) == section }
            let framedSet = Set(framed)
            let onBar = bar.filter(framedSet.contains)
            guard framed.count > 1, onBar != framed else { continue }
            edits.order[section] = framed
            edits.previousOrder[section] = onBar + drawn.filter { !framedSet.contains($0) }
            seeded.append(section)
        }
        UserDefaults.standard.set(true, forKey: Self.orderSeedKey)
        guard !seeded.isEmpty else {
            PelmetLog.log("migrate: stored order matches the bar — nothing to seed")
            return
        }
        settings.orderEdits = edits
        settings.save()
        PelmetLog.log("migrate: stored order for \(seeded.map(\.rawValue).sorted()) differs from the bar — seeded as pending edits")
    }

    /// A drawing that matches the bar again is no edit: an icon dragged
    /// out of a section and back to its slot lit Apply for a zero-move
    /// pass (Timer, 2026-09-20 21:45). Compared on the collapsed-bar view
    /// the count uses; the rules are `OrderEditSettle`'s. A concealed icon
    /// is on the bar, out of the AX tree, and placed only where a frame
    /// remembers its slot: one with none (its section not revealed since
    /// launch) keeps the edit pending.
    private func pruneSettledOrderEdits() {
        guard let snapshot, !settings.orderEdits.isEmpty else { return }
        let bar = ApplyPass.barOrder(ApplyPass.rememberedFrames(snapshot, appState: self))
        // Extras that are not idle are on the bar even while their section
        // hides them (out of the walk and the concealed set alike).
        let ownExtras = Set((extras?.managedItemIDs ?? []).filter { extras?.wouldShow($0) == true }.map(\.sectionKey))
        let settled = OrderEditSettle.settledSections(
            settings.orderEdits, bar: bar, live: Set(snapshot.items.map(\.id)), concealed: snapshot.concealed,
            ownBehindOverflow: ownItemsBehindOverflow, ownExtras: ownExtras,
            itemsAtRest: snapshot.itemsAtRest, roster: settings.sectionModel.roster
        )
        guard !settled.isEmpty else { return }
        var edits = settings.orderEdits
        let cleared = Set(settled.flatMap { edits.order[$0] ?? [] })
        for section in settled { edits.clearOrder(for: section) }
        settings.orderEdits = edits
        PelmetLog.log("editor: drawing matches the bar again — edit cleared (\(settled.map { "\($0)" }.sorted().joined(separator: ", ")))")
        // What the report said of icons whose edits are gone goes with them;
        // the rest (a stray that failed elsewhere) keeps its "not moved" and
        // its Retry.
        if var report = applyReport {
            report.failed.removeAll { cleared.contains($0.sectionKey) }
            report.skipped.removeAll { cleared.contains($0.item.sectionKey) }
            if report != applyReport { applyReport = report }
        }
    }

    /// A removed separator or extra leaves its drawn slot behind in the
    /// pending edits, and every pass then skips it as not on screen (the Dot
    /// removed at 20:43, 2026-09-20). Own items only: a third-party icon that
    /// quit is still a member and comes back.
    private func pruneOrderEditsForRemovedOwnItems() {
        guard !settings.orderEdits.isEmpty else { return }
        let managed = Set(((extras?.managedItemIDs ?? []) + (separators?.managedItemIDs ?? [])).map(\.sectionKey))
        var edits = settings.orderEdits
        var dropped = 0
        for (section, order) in edits.order {
            let kept = order.filter { id in
                guard let bundle = id.bundleID, PelmetBundle.ownIDs.contains(bundle),
                      !id.isPelmetChevron else { return true }
                return managed.contains(id.sectionKey)
            }
            dropped += order.count - kept.count
            edits.order[section] = kept
        }
        guard dropped > 0 else { return }
        settings.orderEdits = edits
        settings.save()
        PelmetLog.log("apply: \(dropped) pending edit(s) for removed own item(s) dropped")
    }

    /// The icon's physical side disagrees with its section (an editor drop
    /// between sections hides it at once but leaves it where it was): the
    /// tile says so until Apply relocates it. Needs the chevron
    /// and the item both on screen to tell.
    func isOutOfPlace(_ id: ItemID) -> Bool {
        guard let snapshot,
              let chevron = pelmetChevronItem(in: snapshot)?.frame else { return false }
        // The clock and Control Center in Hidden sit right of the chevron
        // for good: that is their spot, not a pending move.
        guard !isImmovable(id) else { return false }
        let frames = ApplyPass.primaryFrames(snapshot, appState: self)
        guard let frame = frames[id.sectionKey] else { return false }
        let wantsLeft = settings.sectionModel.section(of: id) != .visible
        return wantsLeft ? frame.midX > chevron.midX : frame.midX < chevron.midX
    }

    /// The icon has a place on the bar right now: live in the snapshot, or
    /// concealed (it drops out of AX then), or seen a moment ago (the same
    /// grace the editor's board gives a tile in a gap). False for one of
    /// Apple's switched off in System Settings › Menu Bar, read off its
    /// switch where macOS keeps one. True while nothing has been read yet,
    /// so a missing icon is never claimed on a guess.
    func isInMenuBar(_ id: ItemID) -> Bool {
        if let on = appleMenuBarSwitches[id.sectionKey] { return on }
        guard let snapshot else { return true }
        let key = id.sectionKey
        if snapshot.items.contains(where: { $0.id.sectionKey == key })
            || snapshot.concealed.contains(where: { $0.sectionKey == key }) { return true }
        return Date.now.timeIntervalSince(lastSeenAt[key] ?? .distantPast) < Self.storedTileGrace
    }

    /// When `isInMenuBar` stops counting a gone icon as there. Nil while the
    /// walk sees it, and once the grace is over.
    func menuBarGraceEnds(_ id: ItemID) -> Date? {
        guard appleMenuBarSwitches[id.sectionKey] == nil, let snapshot, let seen = lastSeenAt[id.sectionKey] else { return nil }
        let key = id.sectionKey
        if snapshot.items.contains(where: { $0.id.sectionKey == key })
            || snapshot.concealed.contains(where: { $0.sectionKey == key }) { return nil }
        let end = seen.addingTimeInterval(Self.storedTileGrace + 0.1)
        return end > .now ? end : nil
    }

    // (Alias healing removed: the model keys on ItemID.sectionKey — bundle-
    // level for third parties — so AX title drift can no longer strand
    // assignments or order entries under stale tags.)

    /// The layout editor's board for a section — see EditorItemsBuilder.
    /// Running-app lookups are memoized per call: the builder consults them
    /// per concealed/stored item, and each LaunchServices query is expensive.
    func editorItems(in section: PelmetCore.Section) -> [ObservedItem] {
        var memo: [String: NSRunningApplication?] = [:]
        func app(_ bundle: String) -> NSRunningApplication? {
            if let cached = memo[bundle] { return cached }
            let found = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            memo[bundle] = found
            return found
        }
        return EditorItemsBuilder.build(
            section: section,
            snapshotItems: snapshot?.items ?? [],
            concealed: snapshot?.concealed ?? [],
            extraItems: settings.extraItems,
            separators: settings.separators,
            model: settings.sectionModel,
            pelmetBundleID: PelmetBundle.mainID,
            isRunning: { app($0) != nil && !absentBundles.contains($0) },
            appName: { app($0)?.localizedName },
            recentlySeen: { Date.now.timeIntervalSince(lastSeenAt[$0.sectionKey] ?? .distantPast) < Self.storedTileGrace },
            destroyed: destroyedKeys,
            drawnNow: snapshot.map(drawnNow(in:)) ?? { _ in true }
        )
    }

    /// An icon the bar took down although Pelmet allowed it — the editor
    /// badges it exactly like one that refused to hide: either way Pelmet
    /// can't manage it, and a launcher is the way out. See CollateralTracker.
    func isDestroyedHost(_ id: ItemID) -> Bool {
        destroyedKeys.contains(id.sectionKey)
    }

    /// The app's running copy lives outside an Applications folder. macOS
    /// matches the allowlist through LaunchServices and misses a copy run
    /// from a build folder, so the assertion hides it whatever Pelmet
    /// allows (DerivedData, proven 2026-08-29; #66's local cmux build).
    func runsOutsideApplications(_ id: ItemID) -> Bool {
        guard let bundle = id.bundleID,
              let path = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.bundleURL?.path
        else { return false }
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return !["/Applications/", "/System/Applications/", homeApplications + "/"].contains { path.hasPrefix($0) }
    }

    // MARK: - Effects

    /// Pelmet-owned items hide by their OWN visibility, not the assertion —
    /// asserting away Pelmet's bundle would take the chevron too.
    var revealedSectionsForExtras: Set<PelmetCore.Section> { currentRevealedSections }

    /// Apple's camera pill is on the bar, which only happens with no
    /// assertion held (a full reveal); Pelmet's indicator defers to it to
    /// avoid duplication. Not while the relay has it up for a click.
    var systemCameraPillVisible: Bool {
        guard !audioVideoRelayActive, !transitions.liftKeepsCameraItem else { return false }
        return (snapshot?.items ?? []).contains {
            $0.id.rawValue.contains("menuextra.audiovideo") && $0.frame != nil
        }
    }

    /// When one of Pelmet's own items last came, left or changed face.
    var ownBarSignature: String { extras?.barSignature ?? "" }

    /// Apple's SharePlay icon is on screen (a full reveal lets it back):
    /// the Camera & mic item steps aside for it as it does for the pill.
    var systemSharePlayVisible: Bool {
        guard !audioVideoRelayActive, !transitions.liftKeepsCameraItem else { return false }
        return (snapshot?.items ?? []).contains {
            $0.id.rawValue.hasSuffix(AudioVideoPill.sharePlayIdentifier) && $0.frame != nil
        }
    }

    /// Sections a picture pass has out on the bar under its cover. Pelmet's
    /// own items follow them like any reveal: told "concealed" mid-pass,
    /// the extras the engine had just shown hid again and the bar bounced
    /// under the capture (2026-10-09).
    @ObservationIgnored var picturePassSections: Set<PelmetCore.Section>?

    /// What is revealed ON THE BAR. A reveal the panel draws leaves the bar
    /// concealed, so Pelmet's own items, covers and pictures stay put.
    var currentRevealedSections: Set<PelmetCore.Section> {
        // Anchored, Hidden is out on the bar whatever the machine says.
        let anchored = transitions.anchored ? transitions.anchoredSections : []
        // A pass says exactly what is out (it adds the anchor itself, and
        // its rounds put every section away).
        if let picturePassSections { return picturePassSections }
        guard !panelShowsReveal else { return anchored }
        switch rehide.state {
        case .revealed(let sections, _):
            return sections.union(anchored)
        case .transitioning(target: .reveal(let sections, _), _):
            // Track the transition's destination so Pelmet-owned items appear
            // in the same swap as the assertion-managed ones.
            return sections.union(anchored)
        default:
            return anchored
        }
    }

    private func dispatch(_ effects: [RehideEffect]) {
        // Extras are NOT applied here: the engine's reflow companion applies
        // them inside the converge so their size change shares the assertion
        // swap's reflow. Applying pre-reflow here put them on a second clock.
        // The chevron flips at transition START — settle-time flips read as an
        // unacknowledged click.
        defer {
            statusItem?.updateSymbol(revealed: isRevealedOrRevealing)
            releaseOrphanedItemsInBar()
        }
        for effect in effects {
            switch effect {
            case .none:
                break
            case .reveal(let sections) where sections.isEmpty:
                // Show in Menu Bar: icons out on their own, no section moves.
                // `revealPresenter` stays as it is: nothing is presented, so
                // a later reveal still routes by its own reason.
                transitions.performItemsReveal(itemsInBar, settles: true, trace: PerfTrace(kind: "reveal", reason: .itemInBar))
            case .reveal(let sections):
                var reason: RevealReason?
                if case .transitioning(target: .reveal(_, let r), _) = rehide.state { reason = r }
                if reason == .hover { hoverRevealStartedAt = .now }
                let trace = PerfTrace(kind: "reveal", reason: reason)
                let decision = revealDecision(for: reason)
                var presenter = reason.map { RevealRouting.destination(for: $0, target: decision.target) } == .panel
                    ? panelPresenter as any RevealPresenter : barPresenter
                if revealPresenter === barPresenter {
                    // The bar is out already: a wider reveal widens it there.
                    presenter = barPresenter
                } else if panelShowsReveal, !RevealRouting.needsBar(reason) {
                    // The panel is up: it takes the wider reveal, wherever
                    // the pointer has gone since.
                    presenter = panelPresenter
                } else if panelShowsReveal {
                    // Something that needs the real bar (⌘↩ in Search, an
                    // Apply) while the panel is up: the panel goes, the
                    // bar takes the reveal.
                    panelPresenter.dismiss()
                }
                if presenter !== revealPresenter {
                    revealDecision = RevealDecision(
                        display: decision.display, uuid: decision.uuid,
                        target: presenter === barPresenter ? .menuBar : decision.target,
                        followsChoice: !RevealRouting.needsBar(reason),
                        holdsOthers: !RevealRouting.needsBar(reason) || reason == .displayPolicy)
                    PelmetLog.log("reveal: \(presenter === barPresenter ? "bar" : decision.target.rawValue) from display \(decision.display.map(String.init) ?? "?") (\(reason.map { "\($0)" } ?? "no reason"))")
                } else if RevealRouting.needsBar(reason) {
                    // The editor or an Apply widens a bar a hover brought
                    // out: every bar shows it now (barsKeptConcealed).
                    revealDecision?.followsChoice = false
                    if reason != .displayPolicy { revealDecision?.holdsOthers = false }
                }
                revealPresenter = presenter
                presenter.reveal(sections, reason: reason, trace: trace)
            case .narrow(let sections):
                // Asked only while the bar holds a settled reveal
                // (`restoreDisplayPolicyAfterPass`): the rest goes back in
                // the same swap, nothing is presented anew.
                var reason: RevealReason?
                if case .transitioning(target: .reveal(_, let r), _) = rehide.state { reason = r }
                transitions.performNarrow(sections, trace: PerfTrace(kind: "narrow", reason: reason))
            case .conceal:
                let trace = PerfTrace(kind: "conceal", reason: nil)
                // Icons Show in Menu Bar had out go back with whatever else
                // goes, or alone when no section was presented.
                let items = takeItemsInBar()
                // The presenter that showed the reveal takes it down; with
                // none up (a conceal at boot, or before any reveal) the bar
                // is where the engine's conceal lands.
                let shown = revealPresenter
                revealPresenter = nil
                revealDecision = nil
                if shown == nil, !items.isEmpty {
                    transitions.performItemsConceal(items, settles: true, trace: trace)
                } else if let shown, shown !== barPresenter {
                    shown.conceal(trace: trace)
                    if !items.isEmpty {
                        transitions.performItemsConceal(items, settles: false, trace: PerfTrace(kind: "conceal", reason: .itemInBar))
                    }
                } else {
                    transitions.performConceal(trace: trace, releasing: items)
                }
                if shown === panelPresenter { restoreShowAllPolicyAfterPanel() }
            case .armTimer(let deadline):
                rehideDeferLogged = false
                scheduleRehideTimer(at: deadline)
            case .cancelTimer:
                rehideTimer?.invalidate()
                rehideTimer = nil
            }
        }
    }

    /// Which display a reveal for `reason` follows and what that display
    /// picked (#88). The rule (`RevealRouting.decidingDisplay`) is the
    /// panel's too, so it opens where this was decided.
    func revealDecision(for reason: RevealReason?) -> RevealDecision {
        let screen = decidingScreen(atBar: reason.map(RevealRouting.startsAtBar) ?? false)
        let uuid = screen?.displayUUIDString
        return RevealDecision(display: screen?.directDisplayID, uuid: uuid, target: settings.revealTarget(forDisplayUUID: uuid))
    }

    /// The display under the pointer; off a bar's reveal, only while a bar
    /// is drawn there (the Window Server's, as `GlassPanel` reads it), then
    /// the active display's, then the primary (the first screen, never
    /// NSScreen.main: that is the key window's).
    func decidingScreen(atBar: Bool) -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return screens.first }
        let active = lastMouseDownDisplay.flatMap { id in screens.first { $0.directDisplayID == id } }
        return RevealRouting.decidingDisplay(
            atBar: atBar, pointer: NSScreen.underPointer, active: active, primary: screens.first
        ) { GlassPanel.drawnBarHeight(of: $0, fresh: true) != nil }
    }

    /// "Show hidden icons in" on the Panel tab: every display without a
    /// choice of its own follows it. The build-time override
    /// (`pelmet.debug.panel`) is gone: left set, it beat the setting
    /// (review SIMP-7).
    var revealTarget: RevealTarget { settings.hiddenIconsIn }

    /// The bars kept looking concealed (#88): macOS draws one set of icons
    /// on every bar, so a display that hides icons wears the empty picture
    /// of its hidden run while they are out for another display — a bar
    /// reveal elsewhere, or the bar anchored out for a display that shows
    /// all. A reveal on the display itself lifts its own. Apply and the
    /// editor keep every bar.
    var barsKeptConcealed: Set<CGDirectDisplayID> {
        var windows: [[String: Any]]?
        return barsKeptConcealed(windows: &windows)
    }

    /// `windows`: the on-screen list, read once for every display's bar
    /// when one needs it and handed back for the caller's own reads. Read
    /// per display, a click on an anchored Mac read it three times.
    func barsKeptConcealed(windows: inout [[String: Any]]?) -> Set<CGDirectDisplayID> {
        var revealedOn: CGDirectDisplayID?
        if let decision = revealDecision, decision.target == .menuBar {
            guard decision.holdsOthers else { return [] }
            revealedOn = decision.display
        } else if !transitions.anchored {
            return []
        }
        let hiding = NSScreen.screens.filter { screen in
            guard let id = screen.directDisplayID, id != revealedOn, id != transitions.pressUnheld else { return false }
            return settings.behavior(forDisplayUUID: screen.displayUUIDString) == .collapse
        }
        guard !hiding.isEmpty else { return [] }
        if windows == nil { windows = ConcealGhostOverlay.onScreenWindows() }
        return Set(hiding.compactMap { screen -> CGDirectDisplayID? in
            // A bar auto-hidden or under a full-screen app draws nothing
            // to keep concealed.
            GlassPanel.drawnBarHeight(of: screen, fresh: true, in: windows) != nil ? screen.directDisplayID : nil
        })
    }

    /// A connected display shows all icons: the bar stays out for it
    /// wherever the pointer is, and the displays that hide icons are held
    /// (`TransitionCoordinator.anchored`, #88).
    var revealAnchored: Bool {
        // The pictures need Screen Recording: without it the pointer's
        // display decides, as before. `pelmet.debug.noAnchor` takes that
        // path with the permission granted (#96).
        screenRecordingGranted
            && !UserDefaults.standard.bool(forKey: "pelmet.debug.noAnchor")
            && settings.anchorsReveal(connectedDisplayUUIDs: NSScreen.screens.map(\.displayUUIDString))
    }

    /// Bring the bar to what the connected displays ask. Only from a
    /// concealed bar: a reveal up settles first, and its conceal calls this.
    func reconcileAnchor(_ why: String) {
        let want = revealAnchored
        guard want != transitions.anchorTarget else { return }
        guard case .concealed = rehide.state else {
            PelmetLog.log("anchor: \(want ? "on" : "off") waits for the conceal — \(why)")
            return
        }
        PelmetLog.log("anchor: \(want ? "on" : "off") — \(why)")
        transitions.setAnchored(want)
    }

    /// A click on a held bar's picture is a click on that bar's empty run.
    private func heldBarClicked(display: CGDirectDisplayID?, clickCount: Int) {
        PelmetLog.log("held: click ×\(clickCount) on display \(display.map(String.init) ?? "?")")
        guard settings.revealTriggers.clickEnabled else { return }
        if clickCount == 1 {
            toggle(reason: .click)
        } else if settings.revealTriggers.doubleClickForAlwaysHidden {
            reveal([.hidden, .alwaysHidden], reason: .doubleClick)
        }
    }

    /// The display's choice changed Panel ↔ Row under the panel it opened.
    func revealRetargeted(_ target: RevealTarget) {
        revealDecision?.target = target
    }

    /// What a reveal on `display` shows the hidden icons in.
    func revealTarget(onDisplay display: CGDirectDisplayID?) -> RevealTarget {
        settings.revealTarget(forDisplayUUID: display.flatMap(NSScreen.uuid(ofDisplay:)))
    }

    /// The panel finished opening or closing: the machine's transition is
    /// over, as when the bar's reveal or conceal settles.
    func panelDidSettle() {
        dispatch(rehide.handle(.transitionSettled))
        settleCatchUp()
        // Visible-section extras go at any reveal; hidden ones wait for the
        // bar (the panel never draws their section on it).
        placeOwnItemsAwaitingReveal()
        if case .concealed = rehide.state {
            bandMonitor?.rearmHoverAfterConceal()
        }
    }

    /// Rehide fires only when the user has actually moved on: while the
    /// pointer is in the menubar band or over an elevated window (an open
    /// status-item menu or popover), the countdown quietly re-arms.
    private func scheduleRehideTimer(at deadline: Date) {
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(
            withTimeInterval: max(0, deadline.timeIntervalSinceNow),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // An Apply pass needs the frames it measured to stay put.
                let bandReason = self.bandMonitor?.rehideDeferReason()
                // An open panel holds while the pointer is on it or on
                // its way there from the bar; a shortcut's until the
                // pointer has been on it.
                let panelHolds = self.panelShowsReveal && self.panelPresenter.holdsReveal
                if self.editorHoldsBar
                    || (!self.transitions.anchored && self.pointerDisplayBehavior == .alwaysShowAll)
                    || self.applying
                    || panelHolds
                    || bandReason != nil {
                    if !self.rehideDeferLogged {
                        self.rehideDeferLogged = true
                        PelmetLog.log("rehide: deferred — editor=\(self.editorHoldsBar) policy=\(self.pointerDisplayBehavior) apply=\(self.applying) panel=\(panelHolds) band=\(bandReason?.rawValue ?? "none")")
                    }
                    self.scheduleRehideTimer(at: Date().addingTimeInterval(AppTiming.rehideDeferRearm))
                } else {
                    self.rehideTriggered(.delayExpired)
                }
            }
        }
    }

    /// Menubar-positional sections: Pelmet's own chevron is the visible/hidden
    /// boundary. Anything sitting LEFT of it (smaller AX x) is adopted into
    /// Hidden; right of it back to Visible. Uses live AX frames — NOT the
    /// agent's positions plist, which lists new items only lazily (M1 finding).
    /// Always-Hidden has no physical marker of its own; its live cluster IS
    /// the boundary — an item dropped among/left of always-hidden members
    /// (only visible during a full reveal) adopts in, one dropped among the
    /// hidden cluster adopts out.
    /// One adoption chain at a time — a burst of drag ends otherwise
    /// spawns N concurrent retry chains, each pulling its own snapshot.
    private var adoptionInFlight = false
    /// A drag-end request that arrived while a chain was running: the
    /// user's drop x is evidence that must not be dropped with it (ChatGPT
    /// ⌘-dragged into Hidden while the 10s pass ran — the drop was lost and
    /// the item never adopted, 2026-09-08). Replayed when the chain ends.
    private var queuedDragEndX: CGFloat?
    private var queuedDropDisplay: CGRect?
    private var queuedDraggedBundle: String?
    /// A drop's chain is running: the bar stays revealed until it has read
    /// where the icon landed (the band's `.drag` rehide hold). A conceal
    /// mid-chain took the dropped icon, still in its old section, off the
    /// bar (2026-09-25).
    private(set) var dropAdoptionInFlight = false
    /// The app whose icon the last ⌘-drag grabbed (the band's hit-test at
    /// mouse-down), nil when unknown.
    private var lastDropBundle: String?

    /// When the band monitor last saw a user ⌘-drag end. The order
    /// supervisor stays out of the way while that adoption lands.
    private(set) var lastUserDragEndedAt: Date?

    /// `dropDisplay`: the bounds (CG global) of the display a drop landed
    /// on when it is not the main one. The pass reads that display's bar
    /// (`BarAdoption.dropBar`).
    func adoptSectionsFromBar(retry: Int = 0, dragEndX: CGFloat? = nil, dropDisplay: CGRect? = nil, draggedBundle: String? = nil) {
        if retry == 0, dragEndX != nil {
            lastUserDragEndedAt = .now
            dropAdoptionInFlight = true
        }
        if retry == 0 {
            // A drop queued behind one still landing keeps its own grabbed
            // app: set at once, the landing one credited the second drag's
            // app (review, 2026-10-13).
            guard !adoptionInFlight else {
                if let dragEndX {
                    queuedDragEndX = dragEndX
                    queuedDropDisplay = dropDisplay
                    queuedDraggedBundle = draggedBundle
                }
                return
            }
            adoptionInFlight = true
            if dragEndX != nil { lastDropBundle = draggedBundle }
        }
        Task {
            // Mid-transition bars give false frames — defer briefly. (Only
            // in-flight transitions block; a settled bar has stable frames.
            // The old post-settle quiet window starved adoption entirely.)
            // An Apply pass blocks too: its drags are not the user's.
            if isTransitioning || applying {
                guard retry < AppTiming.adoptMaxDeferrals else {
                    PelmetLog.log("adopt: gave up after \(retry) deferrals")
                    adoptionInFlight = false
                    dropAdoptionInFlight = false
                    if let queued = queuedDragEndX {
                        queuedDragEndX = nil
                        adoptSectionsFromBar(dragEndX: queued, dropDisplay: queuedDropDisplay, draggedBundle: queuedDraggedBundle)
                    }
                    return
                }
                try? await Task.sleep(for: AppTiming.adoptDeferralDelay)
                adoptSectionsFromBar(retry: retry + 1, dragEndX: dragEndX, dropDisplay: dropDisplay)
                return
            }
            let snap = await engine.snapshot()
            // A transiently empty AX walk (the agent rebuilding mid-reflow —
            // 22 empty passes in one afternoon's log) is not a bar to
            // reconcile against: the drag-end pass read 0 items and the
            // user's ⌘-drag evidence (dragEndX) was lost for good
            // (2026-09-02, Sconce right of media never folded in). Defer
            // like a transition instead of consuming the pass.
            if snap.items.isEmpty, retry < AppTiming.adoptMaxDeferrals {
                PelmetLog.log("adopt: empty snapshot — deferring (retry=\(retry))")
                try? await Task.sleep(for: AppTiming.adoptDeferralDelay)
                adoptSectionsFromBar(retry: retry + 1, dragEndX: dragEndX, dropDisplay: dropDisplay)
                return
            }
            // A drop on another display's bar is read on that bar, with
            // its own copies and chevron: the walk keeps the main display's
            // (live test, 2026-10-13 19:29:50, `BarAdoption.dropBar`).
            let copies = dropDisplay == nil ? [:] : await engine.barCopies()
            let bar = Self.dropBar(snap, copies: copies, display: dropDisplay)
            // The dropped icon is still in MenuBarAgent's drop animation (up
            // to 1.6s on a crowded bar): nothing under the drop yet, and a
            // pass now loses which icon the user moved (2026-09-25). With
            // the grabbed app known, it must be that app's icon.
            if let dragEndX,
               BarAdoption.droppedItem(at: dragEndX, on: bar.map { ($0.id, $0.frame) }, grabbed: lastDropBundle, grabbedOnly: true) == nil,
               retry < AppTiming.adoptMaxDeferrals {
                PelmetLog.log("adopt: nothing under the drop yet — waiting (retry=\(retry))")
                try? await Task.sleep(for: AppTiming.adoptDeferralDelay)
                adoptSectionsFromBar(retry: retry + 1, dragEndX: dragEndX, dropDisplay: dropDisplay)
                return
            }
            defer {
                adoptionInFlight = false
                dropAdoptionInFlight = false
                if let queued = queuedDragEndX {
                    queuedDragEndX = nil
                    PelmetLog.log("adopt: replaying queued drop x=\(Int(queued))")
                    adoptSectionsFromBar(dragEndX: queued, dropDisplay: queuedDropDisplay, draggedBundle: queuedDraggedBundle)
                }
            }
            updateSnapshot(snap)
            PelmetLog.log("adopt: pass (retry=\(retry), items=\(snap.items.count))"
                + (dropDisplay.map { " on the drop's display x=\(Int($0.minX))…\(Int($0.maxX))" } ?? ""))
            adopt(from: snap, bar: bar, dragEndX: dragEndX, offMain: dropDisplay != nil)
        }
    }

    /// Which zone each item sat in at the last pass. Reflows shift every
    /// frame but never an item's relative position — only a real user drag
    /// does. That makes zone-CHANGE the safe adoption trigger: a
    /// settings-assigned item still sitting in its old zone is never
    /// "corrected" back.
    private var lastAdoptionZones: [String: PelmetCore.Section] = [:]
    /// The chevron's x at the last pass — a moved boundary re-baselines
    /// instead of adopting (see BarAdoption.reconcile).
    private var lastAdoptionChevronX: CGFloat?
    private var lastAdoptionPositions: [String: CGFloat] = [:]
    private var lastAdoptionPending: [String: PelmetCore.Section] = [:]

    var isTransitioning: Bool {
        if case .transitioning = rehide.state { return true }
        return false
    }

    /// The band monitor skips drag-end adoption for Apply's own drags: it
    /// adopted one as a user ⌘-drag and reconciled the hidden order from
    /// the bar mid-pass, which snapped the editor's drawing back (Sound,
    /// 2026-09-20 16:56).
    var syntheticDragInFlight: Bool { applying }

    /// The one write path for the engine snapshot mirror (Apply and
    /// engine-event handling route through here). Content-gated: every
    /// assignment fires @Observable invalidation (re-running the editor
    /// pipeline while settings is open), and most snapshots differ only by
    /// `takenAt`.
    private var lastBundlelessIDs: [String] = []
    private var unhideableTracker = UnhideableTracker()
    /// Canonical keys of icons the bar kept showing after Pelmet concealed
    /// them — the editor's "can't hide" badge. See UnhideableTracker.
    private(set) var unhideableKeys: Set<ItemID> = []

    /// The bundles hidden on purpose while an assertion stands: the items
    /// it carries, and every icon drawn into a section concealed right now.
    /// A pass's reveal can push an icon behind the native « and the carried
    /// set loses it; counted unprotected, Velja, Unclutter and DBngin in
    /// Always Hidden read as destroyed by the bar (2026-10-12).
    private func concealingBundles(_ snap: EngineSnapshot) -> Set<String> {
        let carried = Set(snap.concealed.compactMap(\.bundleID))
        guard !carried.isEmpty else { return [] }
        let revealed = currentRevealedSections
        let drawnHidden = settings.sectionModel.assignments
            .filter { !revealed.contains($0.value) }
            .compactMap { $0.key.bundleID }
        return carried.union(drawnHidden)
    }
    private var collateralTracker = CollateralTracker()
    /// Canonical keys of icons the bar destroyed although the allowlist
    /// protects them (#30) — same badge, and the editor keeps their tile
    /// instead of losing them to every section at once. See CollateralTracker.
    private(set) var destroyedKeys: Set<ItemID> = []
    /// Bundles whose bar item is hosted by a bundle-less process (ChatGPT
    /// Classic's helper): the assertion allowlist can't key on such a
    /// process, so Pelmet can't hide the icon reliably — the editor shows it
    /// inactive and offers a launcher without waiting for a failed conceal.
    private(set) var bundlelessHosts: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: AppState.bundlelessKey) ?? []
    ).subtracting(PelmetBundle.ownIDs)
    private static let bundlelessKey = "pelmet.bundlelessHosts"
    /// Bundles whose bar item swallows synthetic ⌘-drags: every Apply move
    /// landed back where it started (Kap's Electron tray, #15). Left where
    /// the app put it; the editor says so and offers a launcher. Sticky
    /// across launches — the item bounces the same way every time, and
    /// re-learning it costs visible drags per session. Cleared by a
    /// verified move (a user's own ⌘-drag).
    private(set) var immovableBundles: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: AppState.immovableKey) ?? []
    ).subtracting(PelmetBundle.ownIDs)
    private static let immovableKey = "pelmet.immovableBundles"

    /// Learned (bounced drags) or known: the agent pins SystemUIServer, and
    /// the clock and Control Center end the bar — they hide through the
    /// system allowlist like Sound, but no drag (real or synthetic) moves them.
    func isImmovable(_ id: ItemID) -> Bool {
        guard let bundle = id.bundleID else { return false }
        return immovableBundles.contains(bundle) || MenuBarPolicy.isPinnedAppleHost(bundle)
            || MenuBarPolicy.isPinnedSystemItem(id)
    }

    /// A third-party item's drags both landed back where they started.
    /// Spends one of its bounces; after the budget the bundle is marked
    /// immovable and stays where its app put it, so a tray that swallows
    /// drags stops being retried every pass. Returns true once marked.
    private static let maxBounces = 3
    private var bounces: [ItemID: Int] = [:]

    @discardableResult
    func noteBounce(_ id: ItemID, at x: CGFloat) -> Bool {
        guard let bundle = id.bundleID else { return false }
        let count = (bounces[id.sectionKey] ?? 0) + 1
        bounces[id.sectionKey] = count
        PelmetLog.log("apply: \(id.rawValue) bounced both drags (x=\(x)) — \(count)/\(Self.maxBounces)")
        guard count >= Self.maxBounces else { return false }
        setImmovable(bundle, true)
        return true
    }

    func setImmovable(_ bundle: String, _ immovable: Bool) {
        guard !PelmetBundle.ownIDs.contains(bundle),
              immovableBundles.contains(bundle) != immovable else { return }
        if immovable { immovableBundles.insert(bundle) } else { immovableBundles.remove(bundle) }
        UserDefaults.standard.set(Array(immovableBundles), forKey: Self.immovableKey)
        PelmetLog.log("editor: immovable \(immovableBundles.sorted())")
    }
    /// Per bundle, the snapshots in a row whose host read against its sticky
    /// mark (`BundlelessMark`).
    private var bundlelessStreak: [String: Int] = [:]

    /// When `pid` started, from the kernel; nil for an unknown pid.
    /// `BundlelessMark` tells a relaunch from a settled host by it (#103).
    nonisolated private static func processStart(_ pid: pid_t) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    func isBundlelessHost(_ id: ItemID) -> Bool {
        id.bundleID.map { bundlelessHosts.contains($0) } ?? false
    }

    /// Items the native « holds on the primary band, from the latest
    /// snapshot (`PlacementGeometry.overflowTrappedCount`). Information for
    /// the editor's note only: Apply reports them as skipped.
    private(set) var overflowTrappedCount = 0
    /// Which icons those are, for the panel's "Didn't fit" (plan S4: the
    /// notice's list, not `ApplyPass.trapped`).
    @ObservationIgnored private(set) var overflowTrappedItems: [ItemID] = []
    private var lastOverflowRead = 0
    /// The editor's full-bar hint: `overflowTrappedCount` once it has held
    /// `AppTiming.overflowNoticeDelay`. Shown at once, the note flashed in
    /// on every drop and shoved the editor down (2026-10-07).
    private(set) var overflowNoticeCount = 0
    @ObservationIgnored private var overflowNoticeTask: Task<Void, Never>?
    /// The first overflow read once the bar has attached at launch.
    @ObservationIgnored private var bootOverflowRead: Task<Void, Never>?
    /// The hold the last skipped overflow read was skipped for (logged once).
    @ObservationIgnored private var overflowSkipLogged: String?
    /// A read a hold skipped and no read has made up for yet: it runs when
    /// the hold ends (`overflowHoldEnded`). The picture pass and the Camera
    /// & mic relay take their at-rest walk while still holding, and no walk
    /// follows: "Didn't fit" and the overflow gate kept the bar of before the
    /// hold, and a boot read under a picture pass was lost.
    @ObservationIgnored private var overflowReadPending = false

    /// A hold that may have skipped an overflow read is over: read the
    /// snapshot in hand, the one the hold's owner took at rest. Waits on if
    /// another hold is still on (the next one's end, or any read, takes it).
    func overflowHoldEnded() {
        guard overflowReadPending, picturePassSections == nil, overflowReadHold == nil, let snapshot else { return }
        PelmetLog.log("overflow: reading the bar the hold left")
        noteOverflow(in: snapshot)
    }

    /// Whether the bar draws `id` right now, for every read of the «
    /// (`ApplyPass.primaryFrames`, `noteOverflow`, the editor's board). A
    /// walk still lists frames the bar no longer draws, on top of their
    /// neighbours: an icon just put away (Pelmet's own extras collapse in
    /// place for 0.7s), which put Siri and Shortcuts in "Didn't fit" after a
    /// picture pass, and an idle indicator a pass attached and let go, which
    /// read Camera & mic and the chevron as two icons behind the «
    /// (2026-10-12). An icon out on its own is drawn whatever its section,
    /// and so is one macOS will not hide (`unhideableKeys`, a bundle-less
    /// host): it stays on the bar with its section concealed.
    func drawnNow(in snap: EngineSnapshot) -> (ItemID) -> Bool {
        let out = currentRevealedSections
        let model = settings.sectionModel
        let alone = Set(snap.shownAlone.map(\.sectionKey))
        let unhideable = unhideableKeys
        let bundleless = bundlelessHosts
        let extras = self.extras
        let ownExtras = Set((extras?.managedItemIDs ?? []).map(\.sectionKey))
        return { id in
            let key = id.sectionKey
            if alone.contains(key) || unhideable.contains(key) { return true }
            if let bundle = id.bundleID, bundleless.contains(bundle) { return true }
            if ownExtras.contains(key), extras?.isShowing(key) == false { return false }
            let section = model.section(of: key)
            return section == .visible || out.contains(section)
        }
    }

    /// Whether `id`'s concealed section is what keeps it off the bar right
    /// now, not the « (`ApplyCount.isConcealed`): the walk just after a
    /// conceal still lists Shortcuts and Sound, leftovers on top of each
    /// other, and the Apply count read both as behind it (live test,
    /// 2026-10-13).
    func concealedNow(in snap: EngineSnapshot) -> (ItemID) -> Bool {
        let drawn = drawnNow(in: snap)
        let concealed = Set(snap.concealed.map(\.sectionKey))
        let out = currentRevealedSections
        let model = settings.sectionModel
        let extras = self.extras
        return { id in
            ApplyCount.isConcealed(
                id, drawn: drawn, concealedKeys: concealed,
                wouldShow: { extras?.wouldShow($0) != false },
                section: { model.section(of: $0) }, revealed: out
            )
        }
    }

    /// Whether the walk has yet to read `id` where the bar draws it now
    /// (`ApplyCount.isUnread`): a drop changes its section before the
    /// converge swaps, and a reveal before its walk lands, so the Apply
    /// count judged Snib's drop into a concealed Hidden from the walk
    /// before it and read "= 0" for 0.55s (live test, 2026-10-13 19:24:25).
    /// An extra shown since the last walk at rest is unread too: Shortcuts
    /// moved to Visible out of a concealed Hidden read "= 0" from its show
    /// until that walk (live test, 2026-10-13 20:24:38).
    func unreadNow(in snap: EngineSnapshot) -> (ItemID) -> Bool {
        let drawn = drawnNow(in: snap)
        let live = Set(snap.items.map(\.id.sectionKey))
        let concealed = Set(snap.concealed.map(\.sectionKey))
        let atRest = snap.itemsAtRest
        let extras = self.extras
        let lastRestWalk = lastRestWalkAt
        let shown = Set((extras?.managedItemIDs ?? []).map(\.sectionKey).filter { key in
            extras?.shownAt(key).map { !ApplyCount.hasWalked(since: $0, lastRestWalk: lastRestWalk) } ?? false
        })
        return {
            ApplyCount.isUnread($0, drawn: drawn, live: live, concealedKeys: concealed, atRest: atRest, shown: shown)
        }
    }

    // MARK: The chevron behind Apple's « (#81)

    /// macOS has put the chevron behind its « (`ChevronTrap`): the bar is
    /// full, and the chevron, the leftmost item drawn, went first. Counted
    /// in the « notice and "Didn't fit", named by the editor's hint.
    private(set) var chevronTrapped = false
    /// The « while the chevron is behind it: the reveal triggers stop at its
    /// left edge (`MenuBarBandMonitor.revealTriggerMaxX`).
    @ObservationIgnored private(set) var chevronTrapToggle: CGRect?
    @ObservationIgnored private var chevronTrapCheck: Task<Void, Never>?
    @ObservationIgnored private var chevronTrapRetry: Task<Void, Never>?
    /// Own extras out of the bar so the chevron fits (`yieldForChevron`),
    /// named by the editor's hint.
    private(set) var chevronYielded: [ItemID] = []
    @ObservationIgnored private var chevronYield: Task<Void, Never>?
    @ObservationIgnored private var chevronYieldedAt: ContinuousClock.Instant?
    /// The last extra's return: the room it came back into, when, and
    /// whether the bar is still to be read for it (`confirmChevronRestore`).
    /// The chevron behind the « again within 5s means that room was short.
    @ObservationIgnored private var chevronRestore: (room: CGFloat, at: ContinuousClock.Instant, unread: Bool)?
    @ObservationIgnored private var shortRoom: ShortRoom?
    @ObservationIgnored private var chevronRestoreLater: Task<Void, Never>?
    /// The bar read again after a return (`confirmChevronRestore`).
    @ObservationIgnored private var chevronRestoreCheck: Task<Void, Never>?
    /// The latest walk, for the room read (`chevronRoom`): a walk's trap and
    /// return reads run before `snapshot` takes it, and read the room from
    /// the walk before (room 60 from the chevron's old frame with 65 drawn,
    /// no return, live test 2026-10-20 08:31:06).
    @ObservationIgnored private var chevronRoomWalk: EngineSnapshot?
    /// That walk's copies on every display's bar, by the walk's time: the
    /// room on a bar other than the main display's (`chevronRoom`).
    @ObservationIgnored private var chevronRoomCopies: (walk: Date, copies: [ItemID: [CGRect]])?
    @ObservationIgnored private var chevronRoomCopiesFetch: Task<Void, Never>?

    /// Reads the chevron against the «, on each walk and each time the
    /// chevron's window changes occlusion. A trap holds 1s before it
    /// counts: a reflow parks the chevron on the « for a moment, as at every
    /// launch on a full bar.
    func checkChevronTrap() {
        guard barAttached, picturePassSections == nil, overflowReadHold == nil else {
            // A full bar sitting still has no walk or occlusion change to
            // come back on: at launch every walk fell inside the attach lead
            // and the trap was never read (live test, 2026-10-19).
            guard chevronTrapRetry == nil else { return }
            chevronTrapRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.chevronTrapRetry = nil
                self?.checkChevronTrap()
            }
            return
        }
        guard settings.showStatusItem, statusItem?.windowOcclusionVisible == false else {
            chevronTrapCheck?.cancel()
            chevronTrapCheck = nil
            setChevronTrapped(false, toggle: nil)
            return
        }
        guard chevronTrapCheck == nil else { return }
        // The « by its label: an occlusion that stays off (a full-screen
        // app, an auto-hidden bar) re-reads it on every walk, and the sweep
        // is about 230 AX hit-tests.
        chevronTrapCheck = Task { [weak self] in
            var toggle = await self?.chevronBarToggle()
            if self?.chevronTrapped == false, self?.chevronParked(on: toggle) == true {
                try? await Task.sleep(for: .seconds(1))
                toggle = await self?.chevronBarToggle()
            }
            guard let self, !Task.isCancelled else { return }
            self.chevronTrapCheck = nil
            // A pass or a « hold that began during the hold reads again after it.
            guard self.picturePassSections == nil, self.overflowReadHold == nil else { return self.checkChevronTrap() }
            self.setChevronTrapped(self.chevronParked(on: toggle), toggle: toggle)
        }
    }

    private func chevronParked(on toggle: CGRect?) -> Bool {
        ChevronTrap.isTrapped(iconShown: settings.showStatusItem, occlusionVisible: statusItem?.windowOcclusionVisible,
                              window: chevronWindowFrame, toggle: toggle)
    }

    private func setChevronTrapped(_ trapped: Bool, toggle: CGRect?) {
        chevronTrapToggle = trapped ? toggle : nil
        // Still behind: a yield that couldn't run when the trap began (the
        // chevron on a screen with no notch, no extra up yet) gets its turn.
        guard trapped != chevronTrapped else {
            if trapped { yieldForChevron() }
            return
        }
        chevronTrapped = trapped
        PelmetLog.log(trapped
            ? "overflow: chevron behind the « (at x=\(Int(toggle?.minX ?? 0)))"
            : "overflow: chevron back on the bar")
        if let snapshot { noteOverflow(in: snapshot) }
        if trapped {
            // The return just made pushed it behind: that extra goes first,
            // and the room is learnt, from a bar at rest (a reveal fills the
            // bar by itself).
            var short: CGFloat?
            if let restore = chevronRestore, ContinuousClock.now < restore.at + .seconds(5), chevronBarBusy == nil {
                learnShortRoom(restore.room)
                short = restore.room
            }
            chevronRestore = nil
            chevronRestoreCheck?.cancel()
            chevronRestoreCheck = nil
            yieldForChevron(shortRoom: short)
        } else {
            restoreForChevronIfRoom()
        }
    }

    /// The chevron's display when it has a notch, with the notch's right
    /// edge. Nil off a notched bar: there the frontmost app's menus set the
    /// room, which can't be measured for an extra to come back, and the
    /// hint stays the answer.
    private func chevronNotchedBar(_ frame: NSRect) -> (screen: NSScreen, notchMaxX: CGFloat)? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }),
              let notch = screen.auxiliaryTopRightArea else { return nil }
        return (screen, notch.minX)
    }

    /// The room left of the drawn chevron's bar (`ChevronTrap.room`), from
    /// its left end (`ChevronTrap.leftEdge`): the icons `walk` reads drawn
    /// on the chevron's display. The walk frames the main display's bar;
    /// another display's is read from its `copies` there.
    private func chevronRoom(_ frame: NSRect, on bar: (screen: NSScreen, notchMaxX: CGFloat), walk: EngineSnapshot,
                             copies: [ItemID: [CGRect]]?) -> CGFloat {
        // Only what the bar draws now (`drawnNow`, which leaves out an extra
        // put away, its frame still read for 0.7s): the walk just after a
        // conceal still lists hidden icons where they stood, and pulled the
        // left end in to a room of 1 (review, 2026-10-20).
        let drawn = drawnNow(in: walk)
        let concealed = Set(walk.concealed.map(\.sectionKey))
        let display = bar.screen.directDisplayID.map(CGDisplayBounds)
        let frames = walk.items.compactMap { item -> CGRect? in
            guard drawn(item.id), !concealed.contains(item.id.sectionKey) else { return nil }
            if let copies {
                return display.flatMap { display in copies[item.id].flatMap { MenuBarGeometry.copy(onDisplay: display, among: $0) } }
            }
            guard let f = item.frame, PlacementGeometry.isPrimary(f, screenMaxX: bar.screen.frame.maxX) else { return nil }
            return f
        }
        let edge = ChevronTrap.leftEdge(chevronMinX: frame.minX, frames: frames, notchMaxX: bar.notchMaxX)
        return ChevronTrap.room(leftEdge: edge, notchMaxX: bar.notchMaxX)
    }

    /// The icons `walk` reads drawn, Pelmet's own aside (its extras come and
    /// go for the chevron): the bar a short room was learnt on (`ShortRoom`).
    private func chevronBarKeys(_ walk: EngineSnapshot) -> Set<ItemID> {
        let drawn = drawnNow(in: walk)
        return Set(walk.items.compactMap { item in
            item.id.bundleID.map(PelmetBundle.ownIDs.contains) != true && drawn(item.id) ? item.id.sectionKey : nil
        })
    }

    private func learnShortRoom(_ room: CGFloat) {
        shortRoom = ShortRoom(room: room, bar: (chevronRoomWalk ?? snapshot).map(chevronBarKeys) ?? [])
    }

    /// Another display arrangement is another bar: a room learnt on the old
    /// one doesn't hold there.
    private func chevronDisplaysChanged() {
        chevronRoomCopies = nil
        guard let short = shortRoom else { return }
        shortRoom = nil
        PelmetLog.log("extras: displays changed, \(Int(short.room))pt is read again")
    }

    /// The walk's copies for another display's bar, then the return again.
    private func fetchChevronRoomCopies(for walk: Date) {
        guard chevronRoomCopiesFetch == nil else { return }
        chevronRoomCopiesFetch = Task { [weak self] in
            guard let copies = await self?.engine.barCopies() else { return }
            self?.chevronRoomCopiesFetch = nil
            self?.chevronRoomCopies = (walk, copies)
            self?.restoreForChevronIfRoom()
        }
    }

    /// What has the bar besides its icons now, nil at rest: a pass, a «
    /// hold, Apply placing, a reveal.
    private var chevronBarBusy: String? {
        if picturePassSections != nil { return "pass" }
        if overflowReadHold != nil { return "« hold" }
        if applying { return "placing" }
        if !currentRevealedSections.isEmpty { return "revealed" }
        return nil
    }

    /// Makes room for the chevron with Pelmet's own extras in Visible,
    /// nearest it first, one at a time until it draws again: no clicks, no
    /// drags. Each frees about 42pt on the built-in. With `shortRoom`, the
    /// extra that just came back into it goes first.
    private func yieldForChevron(shortRoom: CGFloat? = nil) {
        guard chevronYield == nil, let frame = chevronWindowFrame, chevronNotchedBar(frame) != nil else { return }
        chevronYield = Task { [weak self] in
            var shortRoom = shortRoom
            while let self, self.chevronTrapped,
                  (shortRoom.flatMap { self.extras?.yieldRestoredAgain(shortRoom: $0) } ?? self.extras?.yieldOne()) != nil {
                shortRoom = nil
                self.chevronYieldedAt = .now
                self.chevronYielded = self.extras?.yieldedKeys ?? []
                // The ghost hide leaves layout at 0.7s (`StatusItemFader`).
                try? await Task.sleep(for: .seconds(1.2))
                // The next only while the chevron is still parked on a listed
                // «: occlusion alone also stays off on a locked screen, under
                // a full-screen app or an auto-hidden bar, and the loop
                // emptied Visible there (review, 2026-10-19).
                let toggle = await self.chevronBarToggle()
                guard self.chevronParked(on: toggle) else { break }
            }
            self?.chevronYield = nil
        }
    }

    /// Brings an extra back once the chevron has room for it, one at a
    /// time: on each walk (the bar changed), and 30s after the last went
    /// out at the earliest, so a bar that flaps doesn't flap the extras.
    private func restoreForChevronIfRoom() {
        guard let extras else { return }
        // An extra removed in Settings meanwhile has left the list.
        if chevronYielded != extras.yieldedKeys { chevronYielded = extras.yieldedKeys }
        func all() {
            extras.restoreAllYielded()
            chevronYielded = []
            shortRoom = nil
            chevronRestore = nil
            chevronRestoreCheck?.cancel()
            chevronRestoreCheck = nil
        }
        // No chevron to make room for.
        guard settings.showStatusItem else { return all() }
        // A return whose read gave up on a busy bar is read on the next walk.
        if let restore = chevronRestore, restore.unread, chevronRestoreCheck == nil {
            return confirmChevronRestore(room: restore.room)
        }
        // A short room is learnt for the extras out now, never for good. Kept
        // while the trap's yield is on its way: the trap learns the room
        // first, and a walk before the yield ran read an empty list and
        // forgot it, so the same return came back every 30s (review,
        // 2026-10-20).
        guard !chevronYielded.isEmpty else {
            if chevronYield == nil { shortRoom = nil }
            return
        }
        guard let frame = chevronWindowFrame else { return }
        guard let bar = chevronNotchedBar(frame) else {
            // The chevron on a screen with no notch (its bar follows the
            // active display): nothing to measure there, and bringing them
            // all back yielded them again at each switch (review,
            // 2026-10-19). They wait for the notched bar, or come back once
            // no notched screen is left (the lid closed).
            if !NSScreen.screens.contains(where: { $0.auxiliaryTopRightArea != nil }) { all() }
            return
        }
        guard chevronYield == nil, chevronRestoreCheck == nil, !chevronTrapped, barAttached, chevronBarBusy == nil,
              statusItem?.windowOcclusionVisible == true else { return }
        // A walk mid-move reads icons on their way: the walk at rest after it
        // decides (`updateSnapshot` takes it even when it reads the same).
        guard let walk = chevronRoomWalk ?? snapshot, walk.itemsAtRest else { return }
        var copies: [ItemID: [CGRect]]?
        if bar.screen.directDisplayID != NSScreen.screens.first?.directDisplayID {
            // The walk frames the main display's bar: a built-in that isn't
            // the main display is read from the same walk's copies there.
            guard let held = chevronRoomCopies, held.walk == walk.takenAt else {
                return fetchChevronRoomCopies(for: walk.takenAt)
            }
            copies = held.copies
        }
        let room = chevronRoom(frame, on: bar, walk: walk, copies: copies)
        if let short = shortRoom, !short.holds(on: chevronBarKeys(walk)) {
            PelmetLog.log("extras: the bar changed, \(Int(short.room))pt is read again")
            shortRoom = nil
        }
        // A full bar at rest has no walk to come back on.
        let due = max(chevronYieldedAt.map { $0 + .seconds(30) } ?? .now, chevronRestore.map { $0.at + .seconds(2) } ?? .now)
        guard ContinuousClock.now >= due else {
            if chevronRestoreLater == nil {
                chevronRestoreLater = Task { [weak self] in
                    try? await Task.sleep(until: due, clock: .continuous)
                    self?.chevronRestoreLater = nil
                    self?.restoreForChevronIfRoom()
                }
            }
            return
        }
        guard extras.restoreYielded(room: room, failedRoom: shortRoom?.room) != nil else { return }
        chevronRestore = (room, .now, true)
        chevronYielded = extras.yieldedKeys
        confirmChevronRestore(room: room)
    }

    /// Reads the bar again once the agent has laid a return out
    /// (`RestoreCheck`): a « read 1.2s after it and still there 1.2s later
    /// means the extra didn't fit after all, wherever the agent put it
    /// (behind the «, or pushing the chevron there; the trap read has that
    /// one first). A return only runs with no « on the bar (`chevronRoom`
    /// counts an icon parked on one), so a « that stays is this return's.
    /// The extra goes out again and the room it failed at is learnt
    /// (`ShortRoom`), so it can't flap. Reads count only with the bar at
    /// rest: a return while audio plays places MediaControls (`applying`
    /// from 600ms), and a hover reveal or an item press has a bar of its
    /// own. A read dropped then left the « and the extra behind it, as at
    /// 22:47:38 (review, 2026-10-20). Busy for 30s, the next walk reads it.
    /// The next return waits for the read.
    private func confirmChevronRestore(room: CGFloat) {
        chevronRestoreCheck = Task { [weak self] in
            var check = RestoreCheck()
            var waited = false
            for _ in 0..<25 {
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, !Task.isCancelled else { return }
                if let busy = self.chevronBarBusy {
                    if !waited { PelmetLog.log("extras: the return's read waits, the bar is busy (\(busy))") }
                    waited = true
                    continue
                }
                let toggle = await self.chevronBarToggle()
                // Busy meanwhile: the read is the busy bar's.
                guard !Task.isCancelled else { return }
                guard self.chevronBarBusy == nil else { continue }
                switch check.read(toggleOnBar: toggle != nil) {
                case nil:
                    continue
                case .fits:
                    self.chevronRestoreCheck = nil
                    self.chevronRestore?.unread = false
                    if waited { PelmetLog.log("extras: the return read at rest, no «") }
                    self.restoreForChevronIfRoom()
                case .short:
                    self.chevronRestoreCheck = nil
                    self.chevronRestore = nil
                    self.learnShortRoom(room)
                    guard let extras = self.extras, extras.yieldRestoredAgain(shortRoom: room) != nil else { return }
                    self.chevronYieldedAt = .now
                    self.chevronYielded = extras.yieldedKeys
                }
                return
            }
            self?.chevronRestoreCheck = nil
            PelmetLog.log("extras: the return's read gave up, the bar was busy for 30s")
        }
    }

    /// The « on the chevron's bar, by its label
    /// (`OverflowToggle.listedToggles`): with a bar on each display, the
    /// first the agent lists can be another display's (review,
    /// 2026-10-20). Nil when that bar has none.
    private func chevronBarToggle() async -> CGRect? {
        let display = chevronWindowFrame.flatMap { frame in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
        }?.directDisplayID.map(CGDisplayBounds)
        let toggles = await Task.detached { OverflowToggle.listedToggles().map(\.frame) }.value
        guard let display else { return toggles.first }
        return toggles.first { MenuBarGeometry.isInBand($0, ofDisplay: display) }
    }

    private func noteOverflow(in snap: EngineSnapshot) {
        // A pass's bar is under its cover, a whole bar out at once: what it
        // pushes behind the « is not the bar anyone sees, and "Didn't fit"
        // flashed Snib and the chevron mid-pass (2026-10-12 23:20). The read
        // after it conceals decides again.
        guard picturePassSections == nil else {
            overflowReadPending = true
            return
        }
        // Apply and the item menu relay expand the « themselves: read then,
        // it held nothing, the notice reset at once and needed two reads and
        // 2s to come back after (2026-10-13). The read after the hold decides.
        if let hold = overflowReadHold {
            overflowReadPending = true
            if overflowSkipLogged != hold {
                overflowSkipLogged = hold
                PelmetLog.log("overflow: read skipped — \(hold)")
            }
            return
        }
        overflowSkipLogged = nil
        overflowReadPending = false
        // The bar is still attaching for `bootOwnItemLead` after the own
        // items arrive: the chevron lands on its neighbours, and now-playing,
        // Fast User Switching and the chevron read as behind the « for 0.8s
        // at every launch (2026-10-12). One read when the lead is over decides.
        guard barAttached else {
            if let attached = barAttachesAt, bootOverflowRead == nil {
                bootOverflowRead = Task { [weak self] in
                    try? await Task.sleep(until: attached, clock: .continuous)
                    guard let self, let snapshot = self.snapshot else { return }
                    self.noteOverflow(in: snapshot)
                }
            }
            return
        }
        let primaryMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        // Only what the bar draws now (`drawnNow`). A frame 4pt wide or less
        // never overlaps another by more than the « test's tolerance.
        let drawn = drawnNow(in: snap)
        let framed = snap.items.filter { item in
            guard let f = item.frame, drawn(item.id) else { return false }
            return PlacementGeometry.isPrimary(f, screenMaxX: primaryMaxX)
        }
        var trappedItems = PlacementGeometry.overflowTrapped(framed.map { $0.frame! }).map { framed[$0].id }
        // A lone chevron behind the « overlaps nothing, its frame parked on
        // the « (#81): `chevronTrapped` reads it, already held for 1s.
        if chevronTrapped, let chevron = pelmetChevronItem(in: snap)?.id, !trappedItems.contains(chevron) {
            trappedItems.append(chevron)
        }
        let trapped = trappedItems.count
        // Two consecutive reads to enter (a mid-attach walk at boot read two
        // items at one x for 200ms), one to leave.
        defer { lastOverflowRead = trapped }
        if trapped > 0, overflowTrappedCount == 0, lastOverflowRead == 0, !chevronTrapped { return }
        // Same count, other icons (Velja behind the « where Snib was): the
        // list follows every read the count takes, or "Didn't fit" kept
        // naming the icon that had left.
        overflowTrappedItems = trappedItems
        guard trapped != overflowTrappedCount else { return }
        if (trapped > 0) != (overflowTrappedCount > 0) {
            PelmetLog.log(trapped > 0
                ? "overflow: \(trapped) icon(s) behind the native « — \(trappedItems.map(\.rawValue).joined(separator: ", "))"
                : "overflow: cleared")
        }
        overflowTrappedCount = trapped
        if trapped == 0 {
            overflowNoticeTask?.cancel()
            overflowNoticeTask = nil
            overflowNoticeCount = 0
        } else if overflowNoticeCount > 0 {
            overflowNoticeCount = trapped
        } else if overflowNoticeTask == nil {
            overflowNoticeTask = Task { [weak self] in
                try? await Task.sleep(for: AppTiming.overflowNoticeDelay)
                guard let self, !Task.isCancelled else { return }
                self.overflowNoticeTask = nil
                self.overflowNoticeCount = self.overflowTrappedCount
            }
        }
    }

    /// Remembers the left-to-right order of each section that was just
    /// revealed. Reads the snapshot already in hand: no walk, nothing
    /// awaited. Concealed items have no frame (they leave the AX tree), so
    /// only a section on the bar gets an order, and a walk that saw none of
    /// a section's items keeps the order it had. One that saw a part (icons
    /// out on their own) is merged in, not taken as the whole order.
    func recordDrawnOrder(_ snap: EngineSnapshot, revealed sections: Set<PelmetCore.Section>) {
        let roster = settings.sectionModel.roster
        let bar = ApplyPass.barOrder(ApplyPass.primaryFrames(snap, appState: self)).map(\.sectionKey)
        for section in sections where section != .visible {
            let drawn = bar.filter { roster.section(of: $0) == section }
            guard !drawn.isEmpty else { continue }
            let previous = lastDrawnOrder[section] ?? settings.sectionModel.order[section] ?? []
            lastDrawnOrder[section] = PanelModel.mergedDrawnOrder(previous, drawn: drawn)
        }
    }

    /// The last `remember:` line's icons (logged on change).
    private var lastAloneLine: [String] = []

    /// The primary-band frames `snap` read in their slot.
    private func inSlotFrames(_ snap: EngineSnapshot, primary: [ItemID: CGRect]) -> [ItemID: CGRect] {
        // An icon out on its own sits beside the chevron, and one the swap
        // just concealed is still read where it last stood: neither is its
        // slot. Remembered, the next drop's baseline (`barBasedOrder`) drew
        // Velja and Unclutter, pictured a round at a time from behind the «,
        // after Wi-Fi and Apply dragged them there (2026-10-12 22:50).
        let notInSlot = Set(snap.shownAlone.map(\.sectionKey)).union(snap.concealed.map(\.sectionKey))
        return primary.filter { !notInSlot.contains($0.key) }
    }

    /// A pass dragged icons where concealed ones sit: `snap` is a walk after
    /// its last drag, before it conceals again. What that walk reads in its
    /// slot is remembered as usual; every other frame is forgotten until a
    /// walk at rest frames it (`FrameMemory.forget`).
    func rereadFramesAfterPass(_ snap: EngineSnapshot) {
        updateSnapshot(snap)
        let stale = frameMemory.forget(allBut: Set(inSlotFrames(snap, primary: ApplyPass.primaryFrames(snap, appState: self)).keys))
        let concealedStale = stale.intersection(snap.concealed.map(\.sectionKey)).map(\.rawValue).sorted()
        if !stale.isEmpty {
            let shownStale = stale.subtracting(snap.concealed.map(\.sectionKey)).map(\.rawValue).sorted()
            PelmetLog.log("remember: \(stale.count) frame(s) the walk after the pass did not read wait for a walk at rest, concealed \(concealedStale), shown \(shownStale)")
        }
    }

    func updateSnapshot(_ snap: EngineSnapshot) {
        defer {
            if transitions.anchored {
                transitions.refreshHeld("items moved")
            } else if launchBaselineApplied, case .concealed = rehide.state, revealAnchored, !transitions.anchorTarget,
                      transitions.anchorFailedAt.map({ -$0.timeIntervalSinceNow > 30 }) ?? true {
                // An anchor that found no bar to picture (a locked screen at
                // launch) tries again once the bar reads.
                reconcileAnchor("items moved")
            }
        }
        let now = Date.now
        // Kept even when the walk reads as the snapshot in hand and is
        // dropped below: it read the bar at rest all the same, and an extra
        // shown before it is read (`unreadNow`).
        if snap.itemsAtRest, snap.takenAt > (lastRestWalkAt ?? .distantPast) { lastRestWalkAt = snap.takenAt }
        chevronRoomWalk = snap
        checkChevronTrap()
        restoreForChevronIfRoom()
        noteOverflow(in: snap)
        let primary = ApplyPass.primaryFrames(snap, appState: self)
        let chevronMidX = pelmetChevronItem(in: snap).flatMap { primary[$0.id.sectionKey]?.midX }
        frameMemory.remember(inSlotFrames(snap, primary: primary), chevronMidX: chevronMidX, atRest: snap.itemsAtRest)
        let ownLive = Set(snap.items.compactMap { item in
            item.id.bundleID.map(PelmetBundle.ownIDs.contains) == true ? item.id.sectionKey : nil
        })
        let ownBehind = ownLive.contains { primary[$0] == nil }
            ? ownLive.intersection(ApplyPass.trapped(snap, appState: self)) : []
        let behindNow = ownItemsBehindOverflow.subtracting(ownLive).union(ownBehind)
        if behindNow != ownItemsBehindOverflow {
            ownItemsBehindOverflow = behindNow
            PelmetLog.log("apply: own \(behindNow.map(\.rawValue).sorted()) last seen behind the «, their drawing waits")
        }
        let alone = snap.shownAlone.map(\.sectionKey).filter { primary[$0] != nil }.map(\.rawValue).sorted()
        if alone != lastAloneLine {
            lastAloneLine = alone
            if !alone.isEmpty { PelmetLog.log("remember: \(alone) out on their own, slot frames kept") }
        }
        for item in snap.items {
            lastSeenAt[item.id.sectionKey] = now
            if item.pid > 0, let bundle = item.id.bundleID { lastSeenPID[bundle] = item.pid }
        }
        for id in snap.concealed { lastSeenAt[id.sectionKey] = now }
        pruneRetiredAppleHostSlot(snap)
        // A walk at rest replaces one that was not even when it reads the
        // same: kept, the old one held every settle until the bar changed.
        let comesToRest = snapshot?.itemsAtRest == false && snap.itemsAtRest
        guard snapshot?.contentEquals(snap) != true || comesToRest else { return }
        let bundleless = snap.items.filter(\.hostIsBundleless).map(\.id.rawValue)
        if bundleless != lastBundlelessIDs {
            lastBundlelessIDs = bundleless
            PelmetLog.log("snapshot: bundle-less hosts \(bundleless)")
        }
        // Remembered per bundle: the item drops out of AX while concealed
        // and the editor must not flicker between states across reveals.
        // Sticky and persisted: the same icon is hosted by the helper on one
        // pass and by the main app on the next (ChatGPT Classic re-registers
        // at runtime), and the item is invisible to AX while concealed — a
        // mark that came and went with the reveal state was worse than none.
        // An app that EVER draws its bar icon from a bundle-less helper can't
        // be hidden reliably; the user clears it by fixing the app.
        for item in snap.items {
            if let bundle = item.id.bundleID { absentBundles.remove(bundle) }
        }
        // One sighting is not evidence: a walk that lands mid-relaunch finds
        // a pid LaunchServices has no record of yet and reads a perfectly
        // normal app as bundle-less (Sconce and a Pelmet launcher, both
        // 2026-09-14; the read cleared 75ms later). A real bundle-less host
        // (ChatGPT Classic's helper) reads that way on every walk. So: mark
        // after `BundlelessMark.confirmations` consecutive live sightings,
        // and unmark a host that reads fine that many times in a row — the
        // "fix the app" recovery happens on its own. Once concealed, though,
        // a bundle-less host's icon is never live again: a launch reads it
        // once, before the first swap, and the mark never landed (#103). A
        // host that has run for a while is no relaunch, so that one sighting
        // marks it (`BundlelessMark.settledHostAge`). Never Pelmet's bundles.
        var readings: [String: Bool] = [:]
        var hostAges: [String: TimeInterval] = [:]
        for item in snap.items where item.frame != nil {
            guard let bundle = item.id.bundleID, !PelmetBundle.ownIDs.contains(bundle) else { continue }
            readings[bundle] = (readings[bundle] ?? false) || item.hostIsBundleless
            if item.hostIsBundleless, !bundlelessHosts.contains(bundle), let started = Self.processStart(item.pid) {
                hostAges[bundle] = max(hostAges[bundle] ?? 0, -started.timeIntervalSinceNow)
            }
        }
        var changed = false
        for (bundle, bundleless) in readings {
            let before = bundlelessStreak[bundle] ?? 0
            let step = BundlelessMark.step(
                marked: bundlelessHosts.contains(bundle), bundleless: bundleless, streak: before, hostAge: hostAges[bundle])
            bundlelessStreak[bundle] = step.streak > 0 ? step.streak : nil
            guard step.flips else { continue }
            if bundleless { bundlelessHosts.insert(bundle) } else { bundlelessHosts.remove(bundle) }
            if bundleless, before + 1 < BundlelessMark.confirmations, let age = hostAges[bundle] {
                PelmetLog.log("editor: \(bundle) marked on one sighting, its bundle-less host has run \(Int(age))s")
            }
            changed = true
        }
        if changed {
            UserDefaults.standard.set(Array(bundlelessHosts), forKey: Self.bundlelessKey)
            PelmetLog.log("editor: bundle-less hosts \(bundlelessHosts.sorted())")
        }
        unhideableTracker.observe(
            live: Set(snap.items.filter { $0.frame != nil }.map(\.id.sectionKey)),
            concealed: Set(snap.concealed.map(\.sectionKey))
        )
        if unhideableTracker.confirmed != unhideableKeys {
            unhideableKeys = unhideableTracker.confirmed
            PelmetLog.log("snapshot: unhideable \(unhideableKeys.map(\.rawValue))")
        }
        // Third-party keys only: Apple's modules come and go with the
        // assertion's system flags, not with an allowlist the agent can fail
        // to match, and Pelmet's own items are never collateral.
        collateralTracker.observe(
            live: Set(
                snap.items
                    .filter { $0.frame != nil && !$0.id.isSystemModule }
                    .map(\.id.sectionKey)
                    .filter { $0.bundleID.map { !PelmetBundle.ownIDs.contains($0) } ?? false }
            ),
            concealing: concealingBundles(snap),
            running: { NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty == false }
        )
        if collateralTracker.confirmed != destroyedKeys {
            destroyedKeys = collateralTracker.confirmed
            PelmetLog.log("snapshot: destroyed by the bar \(destroyedKeys.map(\.rawValue))")
        }
        snapshot = snap
        grouper.noteChange()
        seedOrderEditsFromStoredOrderIfNeeded(snap)
        // A drawing the bar already matches clears itself here too, not only
        // after an editor drop: an app quitting or the grouper's own pass can
        // settle it, and Apply stayed lit with nothing to move.
        if !applying {
            let before = settings.orderEdits
            pruneSettledOrderEdits()
            if settings.orderEdits != before { settings.save() }
        }
        let isClock = { (id: ItemID) in id.rawValue.hasSuffix("::com.apple.menuextra.clock") }
        if let frame = snap.items.first(where: { isClock($0.id) })?.frame {
            clockRelay?.updateClockFrame(frame)
        } else if snap.concealed.contains(where: isClock) {
            clockRelay?.clockConcealed()
        }
        bundleCounts = snap.items.reduce(into: [:]) { counts, item in
            guard let bundle = item.id.bundleID else { return }
            counts[bundle, default: 0] += 1
        }
    }

    /// Live items per bundle — the editor's sibling badge reads this instead
    /// of scanning the whole snapshot per tile.
    private(set) var bundleCounts: [String: Int] = [:]

    /// New-app routing: any third-party bundle never seen before gets its
    /// items assigned to `newItemsDestination`. Runs BEFORE converge so the
    /// engine never shows a new icon the user asked to have hidden. The very
    /// first pass (empty known set) is a silent baseline — nothing moves.
    /// Returns the new items (empty on baseline). Nothing moves them: macOS
    /// spawns new icons at the far left of the status area, the hidden side,
    /// and the editor marks a model-visible newcomer not in place until Apply.
    @discardableResult
    private func registerNewItems(from snap: EngineSnapshot) -> [ItemID] {
        let candidates = Self.registrationCandidates(snap.items.map(\.id))
        var model = settings.sectionModel
        let before = model.knownBundles
        let hosts = Self.foldSystemHosts(into: &model, candidates: candidates)
        let registered = model.registerObservedItems(candidates)
        guard registered || !hosts.isEmpty else { return [] }
        if !hosts.isEmpty {
            PelmetLog.log("register: system host(s) \(hosts.sorted().joined(separator: ", ")) known — not routed")
        }
        let added = model.knownBundles.subtracting(before).subtracting(hosts)
        if registered {
            PelmetLog.log(
                before.isEmpty
                    ? "register: baseline \(model.knownBundles.count) bundle(s)"
                    : "register: new \(added.sorted().joined(separator: ", ")) → \(model.newItemsDestination.rawValue)"
            )
        }
        settings.sectionModel = model
        settings.save()
        guard registered, !before.isEmpty else { return [] }
        return candidates.filter {
            $0.bundleID.map(added.contains) == true
        }
    }

    /// Apple hosts (the input menu, MenuBarAgent's Sound / Battery / Clock)
    /// were in the bar before Pelmet could manage them, so an existing install
    /// meets them as "unknown", never as newly installed. They join
    /// `knownBundles` as baseline instead of routing to `newItemsDestination`;
    /// the relaunch re-slot only needs them known. A fresh install (empty set)
    /// already baselines everything in `registerObservedItems`.
    static func foldSystemHosts(into model: inout SectionModel, candidates: [ItemID]) -> Set<String> {
        guard !model.knownBundles.isEmpty else { return [] }
        let hosts = Set(candidates.compactMap(\.bundleID).filter(MenuBarPolicy.isUnmanagedAppleBundle))
            .subtracting(model.knownBundles)
        model.knownBundles.formUnion(hosts)
        return hosts
    }

    /// The walk's items as the bar a drop landed on draws them
    /// (`BarAdoption.dropBar`): primary-band frames on the main display
    /// (`display` nil), each item's copy on `display`'s bar otherwise.
    private static func dropBar(_ snap: EngineSnapshot, copies: [ItemID: [CGRect]], display: CGRect?) -> [ObservedItem] {
        let primaryMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        let bar = BarAdoption.dropBar(
            items: snap.items.map { ($0.id, $0.frame) }, copies: copies, display: display, primaryMaxX: primaryMaxX
        )
        return zip(snap.items, bar).map { item, read in
            ObservedItem(id: item.id, frame: read.frame, appName: item.appName, hostIsBundleless: item.hostIsBundleless, pid: item.pid)
        }
    }

    /// `bar`: the walk read on the bar the drop landed on (`dropBar`).
    /// `offMain`: that bar is another display's, whose x says nothing
    /// against the main bar's: the chevron and positions baselines are
    /// the main bar's, neither compared nor replaced. Zones are the same
    /// on every bar and carry over.
    private func adopt(from snap: EngineSnapshot, bar items: [ObservedItem], dragEndX: CGFloat? = nil, offMain: Bool = false) {
        // No showStatusItem guard: with the Pelmet icon hidden reconcile
        // falls back to cluster-edge boundaries, where zone adoption applies
        // only to the item the user just dragged — identified here by the
        // drop x (the dragged item lands under the cursor; x is global in
        // both Cocoa and CG space, so no y-flip needed).
        // adoptSectionsFromBar defers while transitioning/settling; this is
        // the last line of defense if called on a stale path.
        guard !isTransitioning else { return }
        // One bar's frames only (`dropBar`). The AX walk carries other
        // displays' bars too (Sconce at x=-265 AND x=1535 in one snapshot,
        // 2026-09-02), and the order fold-in keys "leftmost frame wins" — a
        // left-display copy pinned Sconce to the front of Visible no matter
        // where the user dropped it. Other bars' copies read as unmeasured.
        // Off the main bar only the grabbed app's icon takes the credit: an
        // unnamed stand-in there left its neighbour credited, and `land`
        // cleared the neighbour's pending move (review, 2026-10-13).
        let draggedID: ItemID? = dragEndX.flatMap { x in
            let hit = BarAdoption.droppedItem(
                at: x, on: items.map { ($0.id, $0.frame) }, grabbed: lastDropBundle, grabbedOnly: offMain,
                soleGrabbedSlack: offMain ? 24 : nil
            )
            if let hit { PelmetLog.log("adopt: dragged=\(hit.rawValue)") }
            return hit
        }
        // The user just moved it by hand: whatever swallowed Pelmet's drags
        // before, the mark no longer describes the item.
        if let draggedID, let bundle = draggedID.bundleID { setImmovable(bundle, false) }
        guard let result = BarAdoption.reconcile(
            items: items.map { (id: $0.id, minX: $0.frame?.minX) },
            model: settings.sectionModel,
            previousZones: lastAdoptionZones,
            previousChevronX: offMain ? nil : lastAdoptionChevronX,
            previousPositions: offMain ? [:] : lastAdoptionPositions,
            pendingZones: lastAdoptionPending,
            userDragged: dragEndX != nil,
            pelmetBundleID: PelmetBundle.mainID,
            draggedID: draggedID
        ) else { return }
        for line in result.log { PelmetLog.log(line) }
        // Visible-section live order vs model order — the fold-in's inputs.
        let liveVisible = items
            .filter { settings.sectionModel.section(of: $0.id) == .visible && $0.frame != nil }
            .sorted { $0.frame!.minX < $1.frame!.minX }
            .map { "\($0.id.sectionKey)@\(Int($0.frame!.minX))" }
        PelmetLog.log("adopt: visible live=\(liveVisible) model=\((settings.sectionModel.order[.visible] ?? []).map(\.rawValue))")
        lastAdoptionZones = result.zones
        if !offMain {
            lastAdoptionChevronX = result.chevronX
            lastAdoptionPositions = result.positions
        }
        lastAdoptionPending = result.pendingZones
        if result.changed {
            var model = result.model
            // The user moved it by hand: wherever it started, the bar is
            // the truth now and Discard has nothing to put back.
            // Dragged into the section its drawing files it under, it lands
            // like a pass's icon (`OrderEdits.land`): Vorssaint drawn into
            // Hidden, then ⌘-dragged there, was still listed in Visible's
            // baseline and missing from Hidden's, so Discard drew it last
            // (review, 2026-10-13).
            if let draggedID {
                let key = draggedID.sectionKey
                let drawnIn = settings.orderEdits.order.first { $0.value.contains(key) }?.key
                if drawnIn != nil, drawnIn == result.model.section(of: key) {
                    // Off the main display, the bar it was dropped on: the
                    // main bar may conceal the section, its frames
                    // remembered from before the drag.
                    let bar = offMain
                        ? BarAdoption.barOrder(items.map { ($0.id, $0.frame) })
                        : ApplyPass.barOrder(ApplyPass.rememberedFrames(snap, appState: self))
                    settings.orderEdits.land(key, bar: bar)
                } else {
                    settings.orderEdits.previousSection.removeValue(forKey: key)
                }
            }
            // The editor's drawing outranks the bar until Apply. The
            // periodic pass reconciled the hidden order from the bar
            // between two drops and every tile jumped back (2026-09-20 17:28).
            // Not in the section of a named drag: that drag moved the one
            // icon (M2), and the drawing takes it too, or the order keeper
            // dragged it back to its drawn slot (review, 2026-10-20).
            let draggedSection = draggedID.map { result.model.section(of: $0.sectionKey) }
            for section in settings.orderEdits.order.keys {
                guard section == draggedSection, let order = model.order[section] else {
                    model.order[section] = settings.sectionModel.order[section]
                    continue
                }
                let drawn = Set(settings.orderEdits.order[section] ?? [])
                settings.orderEdits.order[section] = order.filter(drawn.contains)
            }
            settings.sectionModel = model
            settings.save()
            // A ⌘-drag across the chevron can move a separator between
            // sections; its host follows the section (see `moveItem`).
            separators?.sync(with: settings.separators)
            Task {
                await engine.setModel(result.model)
                // M2 (docs/CORE-SETS.md): a user drag or membership change
                // is what goes stale in the own-item order hint — the media
                // replica re-registered inside the hidden run after two
                // drags of it (2026-09-20 15:41) while the camera indicator,
                // whose hint was fresh, came back at its slot. Reseed now so
                // the next fresh registration lands where the bar says.
                await engine.writeOrderHint()
            }
        }
    }

    /// Bounded wait for Pelmet's own separators/extras to appear in the agent's
    /// AX tree before the engine may assert (see launch Task). All items are
    /// still isVisible at this point — hiding happens via the reflow
    /// companion after the engine starts.
    private func waitForOwnItemAdoption() async {
        // Only visible-section items count: hidden-section separators/extras
        // are width-collapsed at first apply and never enter the AX tree, so
        // expecting them would guarantee the timeout.
        var expected = Set(
            settings.separators.map { SeparatorManager.itemID(for: $0) }
                .filter { settings.sectionModel.section(of: $0) == .visible }
        )
        // Media controls are a visible-section item that is only IN the bar
        // while audio plays; with nothing playing it is width-collapsed and
        // never enters the AX tree, so expecting it burned the full 8s on
        // every silent launch (2026-09-16). Wait for it only when it shows.
        for spec in settings.extraItems where spec.kind == .mediaControls {
            let id = ExtrasManager.itemID(for: spec)
            if settings.sectionModel.section(of: id) == .visible, extras?.isShowing(id) == true {
                expected.insert(id)
            }
        }
        // Helper-hosted items hide through the assertion, not a collapsed
        // width, so before the first converge every one the helpers have
        // registered sits in band — and the first converge would park a
        // registration the agent hasn't adopted yet, same as a visible one.
        for id in helperHosts?.hostedLiveIDs ?? [] { expected.insert(id) }
        // Nothing to wait for is adopted now: the grouping gate and the boot
        // overflow read wait on this stamp, and a bar with no visible
        // separator, no media control out and no helper never got one, so
        // "booting" held a stray on the wrong side for good (#81).
        guard !expected.isEmpty else {
            PelmetLog.log("start: own items adopted (none to wait for)")
            ownItemsAdoptedAt = ContinuousClock.now
            return
        }
        let deadline = Date.now.addingTimeInterval(8)
        var missing = expected
        var lastWalk: [ItemID: CGRect?] = [:]
        // Every display's bounds in the walk's CG global space. The walk
        // keeps one copy per item and prefers the main display's; when the
        // built-in overflows at boot (all items still in the bar, music
        // playing) the media control's only copy is the one on a side
        // display — drawn there, so adopted. The wait burned its full 8s on
        // it 3 boots out of 7 (2026-09-21).
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return CGDisplayBounds(number)
        }
        var sideDisplayNoted: Set<ItemID> = []
        while Date.now < deadline {
            // In-band frames only: a registration made while the PREVIOUS
            // instance's assertion still held (relaunch overlap) is present
            // in AX but parked offscreen (x=4800 y=-164, 2026-09-02) — on no
            // display's bar. Counting it as adopted let the first converge
            // assert over it, parking the media control in the wrong zone
            // for the whole session.
            let snap = await engine.snapshot()
            lastWalk = Dictionary(
                snap.items.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a }
            )
            var observed: Set<ItemID> = []
            for item in snap.items {
                guard let frame = item.frame else { continue }
                if MenuBarGeometry.isInBand(frame) {
                    observed.insert(item.id)
                } else if expected.contains(item.id),
                          displays.contains(where: { MenuBarGeometry.isInBand(frame, ofDisplay: $0) }) {
                    observed.insert(item.id)
                    if sideDisplayNoted.insert(item.id).inserted {
                        PelmetLog.log("start: \(item.id.rawValue) drawn on a side display's bar at x=\(Int(frame.minX)) y=\(Int(frame.minY)) — adopted, the built-in copy overflowed")
                    }
                }
            }
            if expected.subtracting(observed).isEmpty {
                PelmetLog.log("start: own items adopted (\(expected.count))")
                ownItemsAdoptedAt = ContinuousClock.now
                return
            }
            missing = expected.subtracting(observed)
            try? await Task.sleep(for: .milliseconds(500))
        }
        // Adoption gave up: the own-item passes must not wait forever.
        ownItemsAdoptedAt = ContinuousClock.now
        let detail = missing.sorted { $0.rawValue < $1.rawValue }.map { id -> String in
            guard let frame = lastWalk[id] else { return "\(id.rawValue) absent-from-AX" }
            guard let frame else { return "\(id.rawValue) no-frame" }
            return "\(id.rawValue) parked x=\(Int(frame.minX)) y=\(Int(frame.minY))"
        }
        PelmetLog.log("start: own-item adoption timeout — continuing without \(detail)")
    }

    private func handle(engineEvent: EngineEvent) {
        switch engineEvent {
        case .itemsChanged:
            // Not before the first converge. `waitForOwnItemAdoption` polls
            // the engine every 500ms, and any id that flips mid-boot (an
            // item still without a frame, SystemUIServer's title resolving
            // on the second walk) makes one of those polls emit
            // itemsChanged. Converging on it asserts over the helpers whose
            // adoption the wait is still waiting for, so the wait could
            // never finish and burned its full 8s (2026-09-16). Nothing is
            // lost: the boot sequence runs registerNewItems + setModel
            // itself, straight after the wait.
            guard engineStarted else { return }
            // Route never-seen bundles to the configured new-items section,
            // then re-converge so the change (or a known bundle rejoining the
            // allowlist) takes effect.
            Task {
                let registered = registerNewItems(from: await engine.snapshot())
                // The walk behind a swap fires this for every transition
                // (concealed items leave and rejoin AX). Converging on it
                // mid-transition superseded the transition's own converge
                // for nothing; a known bundle rejoining the allowlist is
                // picked up by the next converge, a new one is routed now.
                if !isTransitioning || !registered.isEmpty {
                    await engine.setModel(settings.sectionModel)
                }
                updateSnapshot(await engine.snapshot())
                // The system camera pill appearing/vanishing is an
                // itemsChanged — Pelmet's indicator defers to it live. But NOT
                // mid-transition: every reveal/conceal fires itemsChanged
                // (concealed items drop out of AX), and applying here would
                // animate extras on a second clock. The settle catch-up in
                // dispatch covers the transition case.
                guard !isTransitioning else { return }
                extras?.apply(model: settings.sectionModel, revealed: currentRevealedSections, systemCameraPillVisible: systemCameraPillVisible)
                separators?.apply(model: settings.sectionModel, revealed: currentRevealedSections)
            }
        case .mirrorAtRest:
            // The bar read at rest after a swap: a pending reorder the settle
            // left alone on the stamp or the reflow walk is judged here
            // (`pruneSettledOrderEdits` in updateSnapshot). No converge.
            guard engineStarted else { return }
            Task { updateSnapshot(await engine.snapshot()) }
        case .assertionTornDown:
            unhideableTracker.assertionLost()
            collateralTracker.assertionLost()
            // Recovery: force a real converge. (A `.concealRequested` through
            // the rehide machine was a no-op from `.concealed` — the exact
            // state an external teardown usually finds us in.)
            Task { await engine.setModel(settings.sectionModel) }
        case .availabilityChanged(let available):
            engineCanHide = available
        case .convergeFailed:
            // Surfaced in Settings as a banner; never silently retried in a loop.
            break
        }
    }
}
