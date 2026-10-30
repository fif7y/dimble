// TransitionCoordinator.swift
// Reveal/conceal execution, extracted from AppState.dispatch: the overlay
// cover lifecycle (pre-captured reveal cover, conceal ghost, swap-quiet
// holds) around the engine transition. The rehide state machine stays in
// AppState — settle re-entry goes through the onSettled callbacks.

import AppKit
import PelmetCore
import PelmetEngine

/// A style is two moves performed by pictures over the covered bar. Adding a
/// style: a case in `RevealAnimation`, a recipe here, a picker entry.
struct AnimationRecipe {
    enum Move {
        /// There, or gone, in one frame.
        case pop
        /// Opacity only — the picture never moves, so the background under
        /// it never smears (an opaque strip is fine).
        case fade(CFTimeInterval)
        /// Toward/from the chevron by `dx` points with a fade — needs the
        /// icons cut out against the empty bar.
        case slide(dx: CGFloat, CFTimeInterval)

        var needsCutOut: Bool {
            if case .slide = self { return true }
            return false
        }
    }

    let entrance: Move
    let exit: Move

    static func recipe(for style: RevealAnimation) -> AnimationRecipe {
        switch style {
        case .instant: AnimationRecipe(entrance: .pop, exit: .pop)
        case .fade: AnimationRecipe(entrance: .fade(AppTiming.fadeRevealDuration), exit: .fade(AppTiming.fadeExitDuration))
        case .smooth: AnimationRecipe(entrance: .slide(dx: 96, AppTiming.smoothRevealDuration), exit: .slide(dx: 64, AppTiming.smoothExitDuration))
        }
    }
}

@MainActor
final class TransitionCoordinator {
    private weak var appState: AppState?
    private let engine: AgentBarEngine

    init(appState: AppState, engine: AgentBarEngine) {
        self.appState = appState
        self.engine = engine
        backdropWatch.start()
    }

    /// The bar is glass — a window parked under it tints the pictures, and
    /// a window that then moves leaves its edge baked into every reveal
    /// (#33). Checked off the reveal path, on the signals that end a
    /// window move; a changed backdrop drops the stale pictures. The
    /// empty-bar one is retaken on approach, not at once (#49): a window
    /// flickering in and out of the zone on every mouse-up retook it ~40
    /// times per reveal on a four-display Mac, every capture lighting the
    /// screen-recording indicator, while the picture is only ever read at
    /// a reveal. The pointer entering the hover zone is the first sign one
    /// is coming; the reveal itself starts the capture when nothing did.
    private lazy var backdropWatch = BackdropWatch { [weak self] in
        guard let self else { return }
        backdropMayHaveChanged()
        // Anchored, also a bar back from full screen with nothing held.
        if anchored || !held.isEmpty { refreshHeldOnceSettled() }
    }
    private var heldSettle: Task<Void, Never>?

    /// The held pictures, retaken once the backdrop has held still for
    /// `heldBackdropSettle`: each retake films every held bar (~250ms).
    private func refreshHeldOnceSettled() {
        heldSettle?.cancel()
        heldSettle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(AppTiming.heldBackdropSettle))
            guard let self, !Task.isCancelled else { return }
            heldSettle = nil
            refreshHeld("backdrop")
        }
    }
    /// `ConcealGhostOverlay.backdropSignature` at the time each picture was taken.
    private var revealCoverBackdrop: [Int] = []
    private var revealedStripBackdrop: [Int] = []
    /// The cover was dropped for a changed backdrop and not retaken yet.
    private var revealCoverWanted = false
    private var precaptureInFlight = false
    /// Pictures of the last transition still on screen (cover lift, exit
    /// strip). See `awaitPreviousLift`.
    private var liftsInFlight = 0
    /// A cover of a reveal or a re-hide is still up or on its way down.
    var coversInFlight: Bool { liftsInFlight > 0 || liftEnding || liftCover != nil }
    /// What has the bar revealed under its cover: a picture pass or a quiet
    /// Apply. Set and cleared with the press hold it counts as, by
    /// `beginBarHold` / `endBarHold` only. See `awaitPicturePass`.
    private enum BarHold { case picturePass, quietApply }
    private var barHold: BarHold? {
        // The pass took its at-rest walk while holding: an overflow read it
        // skipped runs now, on that walk.
        didSet { if oldValue != nil, barHold == nil { appState?.overflowHoldEnded() } }
    }
    var passInFlight: Bool { barHold != nil }
    /// The pass in flight is a quiet Apply (`holdBarForApply`): seconds of
    /// drags, not a picture pass's one.
    var quietApplyInFlight: Bool { barHold == .quietApply }
    /// A reveal or a press arrived while the pass ran and is waiting for it
    /// (`passWaiterArrived`). The follow-up rounds check it before each
    /// round and stop: the user's bar comes first.
    private var passHasWaiter = false
    /// The dropped cover, kept with the signature it was taken under. Most
    /// changes are one window in and out of the zone (#49's log: 9→8→9;
    /// Notification Center opening and closing under the clock): when the
    /// backdrop comes back exactly, the picture is true again, no capture.
    private var parkedCover: (snapshot: [ConcealGhostOverlay.BarSnapshot], backdrop: [Int], display: CGDirectDisplayID?, underPanel: Bool)?
    /// Notification Center's panel was under the bar when the idle picture
    /// was taken (its shade is in the pixels).
    private var revealCoverUnderPanel = false
    /// Pelmet's own items as the idle picture shows them (`ownBarSignature`
    /// at capture): the backdrop signature can't see them.
    private var revealCoverOwnBar = ""
    /// The bar as it looks under Notification Center's open panel, over the
    /// blink cover's span: taken once after an entrance blink (the panel is
    /// open, the bar quiet), kept while the backdrop, wallpaper and active
    /// display hold. The entrance blink swaps to it once the panel has slid
    /// in: from then on nothing moves under the bar, and a still of that
    /// state is exact (#51).

    private func backdropMayHaveChanged() {
        guard let appState, !revealCoverSnapshot.isEmpty || !revealedStripSnapshot.isEmpty || parkedCover != nil else { return }
        let list = ConcealGhostOverlay.onScreenWindows()
        let now = ConcealGhostOverlay.backdropSignature(of: precaptureRect, in: list) + ConcealGhostOverlay.surfaceSignature()
        if revealCoverSnapshot.isEmpty, let parked = parkedCover, parked.backdrop == now, appState.currentRevealedSections.isEmpty {
            revealCoverSnapshot = parked.snapshot
            revealCoverBackdrop = parked.backdrop
            revealCoverActiveDisplay = parked.display
            revealCoverUnderPanel = parked.underPanel
            parkedCover = nil
            revealCoverWanted = false
            PelmetLog.log("backdrop: back as it was (\((now.count - ConcealGhostOverlay.surfaceSignatureCount) / 5) window(s)) — cover restored, no capture")
        }
        let coverStale = !revealCoverSnapshot.isEmpty && now != revealCoverBackdrop
        let stripStale = !revealedStripSnapshot.isEmpty && revealedStripBackground.isEmpty && now != revealedStripBackdrop
        guard coverStale || stripStale else { return }
        let concealed = appState.currentRevealedSections.isEmpty
        // A stale picture is worse than none: the reveal captures live
        // instead. The cover returns at the next conceal settle if not
        // right now. The finished picture only returns at a reveal settle,
        // and every reveal until then paid the cover-only path (#35) — so
        // when the empty bar it was taken over is still here, keep both:
        // the icons cut out against that empty bar are true whatever moved
        // beneath, and the next reveal composites them over the fresh cover.
        let stripCutOut = stripStale && !revealCoverSnapshot.isEmpty && revealCoverBackdrop == revealedStripBackdrop
        let movers = ConcealGhostOverlay.backdropMovers(from: coverStale ? revealCoverBackdrop : revealedStripBackdrop, to: now, in: list)
        PelmetLog.log("backdrop: changed under the bar (\((now.count - ConcealGhostOverlay.surfaceSignatureCount) / 5) window(s): \(movers)) — cover \(coverStale ? (concealed ? "dropped, retake on approach" : "dropped") : "kept"), finished \(stripStale ? (stripCutOut ? "kept as a cut-out" : "dropped") : "kept")")
        if stripCutOut {
            revealedStripBackground = revealCoverSnapshot
        } else if stripStale {
            revealedStripSnapshot = []
        }
        if coverStale {
            parkedCover = concealed ? (revealCoverSnapshot, revealCoverBackdrop, revealCoverActiveDisplay, revealCoverUnderPanel) : nil
            revealCoverSnapshot = []
            revealCoverWanted = concealed
        }
    }


    /// Notification Center was just dismissed from the clock: once its
    /// slide is over and its window has left the list (~0.6s), take the
    /// bare picture the next click or reveal will want.
    func precaptureAfterPanel() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard revealCoverSnapshot.isEmpty || revealCoverUnderPanel else { return }
            scheduleRevealCoverPrecapture(afterConceal: false)
        }
    }

    /// The pointer entered the hover zone: a reveal is likely within the
    /// hover delay or a click. Retake the dropped cover now so it is ready
    /// (~90ms on Gab's Mac, 150–466ms on #49's), and only now.
    func pointerApproachedBar() {
        guard revealCoverWanted, !precaptureInFlight, revealCoverSnapshot.isEmpty, !pressHoldsBar,
              appState?.currentRevealedSections.isEmpty == true else { return }
        PelmetLog.log("cover: retaking on approach")
        scheduleRevealCoverPrecapture(afterConceal: false)
    }

    /// Battery and Wi-Fi a show rule keeps on the bar (#86), as last sent to
    /// the engine.
    private var ruleShown: Set<ItemID> = []
    /// Those out on their own, their section concealed, by section key: on
    /// the empty bar the pass cuts its crops against (see picturePass).
    private var ruleShownOut: Set<ItemID> {
        guard let model = appState?.settings.sectionModel else { return [] }
        return Set(ruleShown.map(\.sectionKey).filter { model.section(of: $0) != .visible })
    }

    /// A show rule put an icon on the bar or took it back. Both pictures
    /// hold the bar as it was (a ghost Battery in every reveal and clock
    /// cover, or Battery blinking out, until the retake up to 15 minutes
    /// later): drop them, converge, and retake the idle one on the new bar.
    func showRuleChanged(_ items: Set<ItemID>) {
        guard items != ruleShown else {
            Task { await engine.setRuleShown(items) }
            return
        }
        ruleShown = items
        let concealed = appState?.currentRevealedSections.isEmpty ?? false
        PelmetLog.log("cover: a show rule changed the bar (\(items.map(\.rawValue).sorted())) — pictures dropped\(concealed ? ", retaking" : "")")
        revealCoverSnapshot = []
        revealCoverTakenRect = nil
        revealCoverWanted = concealed
        parkedCover = nil
        revealedStripSnapshot = []; revealedStripBackground = []; revealedStripKeep = nil
        Task {
            await engine.setRuleShown(items)
            if appState?.currentRevealedSections.isEmpty == true { scheduleRevealCoverPrecapture() }
            await appState?.liveMirror.showRuleChangedBar()
        }
    }

    /// An item press (ItemPress) has an icon revealed on its own, or the «
    /// expanded, while the rehide machine still reads "concealed": the bar is
    /// not the empty bar the idle picture is of. A picture taken meanwhile
    /// would hold the icon (a ghost in every reveal and clock cover until
    /// the next retake, up to 15 minutes), so no idle picture is taken while
    /// a press holds the bar, and one in flight across a press is dropped.
    private var pressHolds = 0
    private var pressEpoch = 0
    private var pressHoldsBar: Bool { pressHolds > 0 }
    /// A press other than the picture pass's own hold, which counts one.
    private var otherPressHoldsBar: Bool { pressHolds > (passInFlight ? 1 : 0) }

    func pressBegan() {
        pressHolds += 1
        pressEpoch += 1
    }

    /// Until the cover is off the bar: a reveal starting under it would film
    /// the cover as the bar.
    private func beginBarHold(_ hold: BarHold) {
        barHold = hold
        passHasWaiter = false
        pressBegan()
    }

    private func endBarHold() {
        pressEnded()
        barHold = nil
        refreshHeld("the bar is free")
    }

    /// The bar is back as it was: take the idle picture a press kept from
    /// being taken.
    func pressEnded() {
        pressHolds = max(0, pressHolds - 1)
        pressEpoch += 1
        guard pressHolds == 0, revealCoverSnapshot.isEmpty else { return }
        scheduleRevealCoverPrecapture()
    }

    /// A reveal with the cover still wanted: start the capture if nothing
    /// did (the same live capture the no-picture path pays, minus the
    /// Smooth exemption it keeps), then wait for whichever is in flight —
    /// bounded, so a slow capture degrades to the uncovered reveal it
    /// always was rather than holding the bar.
    /// The state machine releases a queued toggle at settle, ~100ms in, but
    /// the pictures lift ~500ms later. A transition started under them
    /// captured and covered on top of a moving picture: the icons vanished
    /// in two frames and the next reveal drew stale copies beside the real
    /// ones (#61, 60fps burst 2026-09-24). Wait them out, bounded.
    private func awaitPreviousLift() async {
        guard liftsInFlight > 0 else { return }
        let started = Date()
        while liftsInFlight > 0, Date().timeIntervalSince(started) < AppTiming.previousLiftWait {
            try? await Task.sleep(for: .milliseconds(15))
        }
        PelmetLog.log("transition: waited \(Int(-started.timeIntervalSinceNow * 1000))ms for the last lift\(liftsInFlight > 0 ? " — still up, going on" : "")")
    }

    /// Tells a running pass that someone is waiting for the bar. Called as
    /// soon as the reveal or the press is asked for, before it starts to wait.
    func passWaiterArrived() {
        if passInFlight { passHasWaiter = true }
    }

    /// A reveal or a press starting during a picture pass would reveal and
    /// conceal over it, and the pass's conceal would take the user's bar
    /// back in. Wait it out, bounded: a pass takes about a second, plus at
    /// most the one follow-up round it finishes once it hears of the waiter.
    func awaitPicturePass() async {
        guard passInFlight else { return }
        passWaiterArrived()
        let started = Date()
        // A quiet Apply runs as long as its drags, and gave up at 4.5s let a
        // Show in Menu Bar reveal over them; its cover's ceiling bounds it.
        let limit = quietApplyInFlight
            ? AppTiming.quietApplyCoverCeiling
            : AppTiming.picturePassWait + AppTiming.picturePassBatch
        while passInFlight, Date().timeIntervalSince(started) < limit {
            try? await Task.sleep(for: .milliseconds(15))
        }
        PelmetLog.log("transition: waited \(Int(-started.timeIntervalSinceNow * 1000))ms for the picture pass\(passInFlight ? " — still running, going on" : "")")
    }

    private func awaitCoverRetake(style: RevealAnimation) async {
        guard revealCoverSnapshot.isEmpty, precaptureInFlight || (revealCoverWanted && style != .smooth) else { return }
        if !precaptureInFlight {
            PelmetLog.log("cover: retaking at the reveal")
            scheduleRevealCoverPrecapture(afterConceal: false)
        }
        let started = Date()
        while precaptureInFlight, Date().timeIntervalSince(started) < AppTiming.coverRetakeWait {
            try? await Task.sleep(for: .milliseconds(15))
        }
        PelmetLog.log("cover: waited \(Int(-started.timeIntervalSinceNow * 1000))ms for the retake — \(revealCoverSnapshot.isEmpty ? "not ready" : "ready")")
    }

    /// Settle re-entry into AppState (rehide machine, settle catch-up,
    /// placement flush / hover re-arm). Wired once at boot.
    var onRevealSettled: (() -> Void)?
    var onConcealSettled: (() -> Void)?
    /// An icons-only reveal had nothing left to bring out.
    var onNothingRevealed: (() -> Void)?

    /// Where the concealed strip last sat — icons reappear in the same spot,
    /// so this rect is the reveal cover's footprint (Instant/Fade styles).
    private(set) var lastConcealedStripRect: CGRect?

    /// Empty-strip snapshot pre-captured while the bar idles concealed — the
    /// reveal path floats it synchronously instead of paying ~100ms+ of SCK
    /// capture before the swap can even start (snappiness).
    private var revealCoverSnapshot: [ConcealGhostOverlay.BarSnapshot] = []
    /// The primary-band rect the idle picture was captured with.
    private var revealCoverTakenRect: CGRect?
    /// The active display (see `AppState.lastMouseDownDisplay`) when each
    /// picture was taken. macOS dims the bar on every other display, so a
    /// picture is only true while the same display stays active: a click
    /// on a dimmed bar activates it as the reveal starts, and the stale
    /// picture floated over it showed the dim bar going bright as it
    /// lifted — the whole bar blinking (Gab, 2026-09-16, three displays).
    private var revealCoverActiveDisplay: CGDirectDisplayID?
    private var revealedStripActiveDisplay: CGDirectDisplayID?
    /// The bars kept looking concealed (#88, `AppState.barsKeptConcealed`),
    /// one picture per display: from a bar reveal on another display until
    /// its conceal has settled, and for as long as the bar is anchored.
    private var held: [CGDirectDisplayID: ConcealGhostOverlay.GhostSet] = [:]
    private var heldDisplays: Set<CGDirectDisplayID> { Set(held.filter { $0.value.isUp }.keys) }
    /// What the latest hold asked for: a hold back from its capture covers
    /// only displays still wanted (a reveal may have lifted one meanwhile).
    private var heldWant: Set<CGDirectDisplayID> = []
    /// Bumped when the displays change: a picture captured across it sits
    /// at the old geometry.
    private var heldDropEpoch = 0
    private var heldCapturesInFlight = 0
    /// The run the held covers show: the wanted run inside the kept
    /// pictures. Bare glass crops to any part with no capture, so a run
    /// that narrowed — the chevron moved left, settled after the reveal or
    /// under a capture indicator — trims the covers off it.
    private var heldShownRun: ClosedRange<CGFloat>?
    /// The icons that run leaves in sight (`heldHoles`).
    private var heldShownHoles: [ClosedRange<CGFloat>] = []
    /// The recording pill on its way to Visible (`AppState.adoptRecordingPill`):
    /// held under the picture where it registered, not cut out of it, so it
    /// shows once, where it lands (Gab, 2026-10-22: the cut, then the move,
    /// was one show too many). A pill that stays put gets its hole after.
    var placingSectionless = false {
        didSet { if placingSectionless != oldValue { refreshHeld("recording pill \(placingSectionless ? "to place" : "placed")") } }
    }
    /// Held pictures take clicks; the pill's drag starts under one.
    var heldPassClicks = false {
        didSet { for cover in held.values { cover.passClicks(heldPassClicks) } }
    }
    /// An anchored press lifted this display's picture for its click.
    private(set) var pressUnheld: CGDirectDisplayID?
    /// The bare run per display, kept so a cover goes back up without a
    /// capture, with the run and the backdrop they were taken over.
    private var heldPictures: [CGDirectDisplayID: ConcealGhostOverlay.BarSnapshot] = [:]
    private var heldPicturesRun: ClosedRange<CGFloat>?
    private var heldPicturesBackdrop: [Int] = []
    /// A connected display shows all icons (`AppState.revealAnchored`): the
    /// engine keeps Hidden out for it and the hiding displays are held, so
    /// each display keeps its behavior wherever the pointer is (#88).
    /// A reveal on a hiding display lifts its picture; Always Hidden still
    /// takes the engine (`anchoredSections`).
    private(set) var anchored = false
    /// The last anchor that found no picture to hold a bar with.
    private(set) var anchorFailedAt: Date?
    private(set) var anchoredSections: Set<PelmetCore.Section> = [.hidden]
    private var anchorTask: Task<Void, Never>?

    /// The widest strip any conceal has measured (left edge only — the
    /// right edge is the same chevron/visible cluster every time). A
    /// hidden-only conceal remembers a short strip; the next full reveal
    /// then slid the always-hidden cluster in UNCOVERED left of it (Sconce's
    /// bar: cover 249px @1352, items landing from 1075 — 2026-09-05).
    private(set) var widestStripMinX: CGFloat?
    /// Concealable items in the last engine snapshot — the floor for the
    /// cover's width before any full conceal has measured the real strip.
    private var concealableCount = 0
    /// Per-item width for that estimate: icons run ~30–36pt with padding,
    /// separators less. Over-covering is free — the cover is a snapshot of
    /// the empty bar floated over the empty bar.
    private static let estimatedItemWidth: CGFloat = 36
    /// The reveal cover's footprint: the remembered strip, widened to the
    /// widest strip ever measured (or the item-count estimate) and padded
    /// generously — left is the slide origin (empty bar, free to cover),
    /// right catches the visible cluster shifting. Strip width drifts
    /// between conceals.
    private var revealCoverRect: CGRect? {
        lastConcealedStripRect.map {
            let estimatedMinX = $0.maxX - CGFloat(concealableCount) * Self.estimatedItemWidth
            let minX = min($0.minX, widestStripMinX ?? $0.minX, estimatedMinX)
            return CGRect(x: minX - 120, y: $0.minY, width: ($0.maxX - minX) + 180, height: $0.height)
        }
    }
    /// What the idle capture actually takes: the reveal cover widened to the
    /// blink's footprint, so one picture serves both and the blink needs no
    /// capture at the click (#45, #46). A wider picture of a static bar is
    /// free — it is taken while the bar idles concealed, and each consumer
    /// crops back to its own rect.
    private var precaptureRect: CGRect? {
        // No strip known yet (no conceal since launch, or a boot that
        // could not seed one): the blink's own rect still serves every
        // clock click (#51: nothing was ever precaptured after a relaunch,
        // every entrance captured live, no under-panel picture existed).
        let blink = barCoverGeometry().map { barCoverRect($0) }
        guard let reveal = revealCoverRect else { return blink }
        guard let blink else { return reveal }
        return reveal.union(blink)
    }
    /// Strip and cover rects are primary-band geometry: an external's copy
    /// of an item stretched the strip across displays (`1278..4887`) and
    /// the blink cover to `-906..1676`, a capture spanning two bars.
    private var primaryMaxX: CGFloat { NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude }

    /// Before the first click of the session the active display is
    /// unknown; the one under the pointer is the one macOS most likely
    /// draws bright, and the one the first click most likely lands on. A
    /// nil stamp made every boot picture unusable at the first reveal
    /// ("another active display (0 → 1)"), one reason the first reveal of
    /// a session was slow.
    private static var displayUnderPointer: CGDirectDisplayID? { NSScreen.underPointer?.directDisplayID }

    private func rememberStrip(_ strip: CGRect?) {
        lastConcealedStripRect = strip
        guard let strip else { return }
        widestStripMinX = min(widestStripMinX ?? strip.minX, strip.minX)
        // The idle picture spans the rect it was taken with. A strip wider
        // than that rect (the boot seed missed Sound; the first conceal
        // measured it) leaves live icons past the picture's edge: Sound
        // popped in after the slide on the external, and a quick hover
        // on/off showed the icons twice, one set standing still while the
        // strip slid out (Gab, 2026-10-02). Drop it, the idle retake
        // spans the new strip.
        if let taken = revealCoverTakenRect, let want = precaptureRect,
           want.minX < taken.minX - 1 || want.maxX > taken.maxX + 1 {
            PelmetLog.log("cover: idle picture \(Int(taken.minX))..\(Int(taken.maxX)) is short of the strip \(Int(want.minX))..\(Int(want.maxX)), retaking")
            revealCoverSnapshot = []
            revealCoverTakenRect = nil
            revealCoverWanted = true
            parkedCover = nil
        }
    }

    // MARK: - Live Activities lift (#106)

    /// When the Live Activities item asked for the reveal it starts to let
    /// the assertion go too (#106). Set right after the request, so the
    /// reveal's own task (which runs later) is the one that takes it; a
    /// conceal first, or no reveal within a moment, and it's dropped.
    var liftRequestedAt: Date?

    /// The bar is out with the assertion let go: from the reveal that takes
    /// the request until the conceal or narrow that ends it. Kept here, on
    /// the main actor, so the item's click reads it at once: the engine is
    /// mid-converge for the whole reveal.
    private(set) var lifted = false

    /// A lift is up or on its way: the item's click takes it back.
    var liftUp: Bool { lifted || liftRequestPending }

    private var liftRequestPending: Bool {
        liftRequestedAt.map { Date().timeIntervalSince($0) < 3 } ?? false
    }

    private func takeLiftRequest() -> Bool {
        defer { liftRequestedAt = nil }
        guard liftRequestPending else { return false }
        lifted = true
        return true
    }

    /// The bar is out already with every section: no reveal is coming to
    /// carry the lift, the engine lets the assertion go on its own.
    func liftOutBar() async {
        lifted = true
        await engine.reveal([], liftingAssertion: true)
    }

    /// Why Pelmet's reads of the bar wait (`AppState.overflowReadHold`, the
    /// order keeper): the pills and the system extras a lift lets back sit
    /// in the bar, pushing the icons left and behind the «, and the re-hide
    /// reflows under its cover. Nil once that cover is down. Only while the
    /// bar is out or settling, so a lift no conceal ended can't hold them.
    var liftHoldReason: String? {
        if liveModeActive { return "the live mirror has the bar" }
        if liftEnding { return "the bar is settling from a Live Activities lift" }
        guard lifted, appState?.currentRevealedSections.isEmpty == false else { return nil }
        return "a Live Activities lift has the bar"
    }

    /// Apple's camera pill comes back with the lift and goes with the
    /// re-hide: Camera & mic must not step aside for it meanwhile, or it
    /// leaves the bar at the lift and comes back after the re-hide, parked
    /// wherever the agent puts it, and Apply drags it home (2.5s after the
    /// re-hide, 2026-10-27). Two camera glyphs for the lift's length instead.
    var liftKeepsCameraItem: Bool { lifted || liftEnding || liveModeActive }

    // MARK: - Live mode

    /// The live mirror holds the bar: the assertion is down under its
    /// cover (`LiveMirror`). Reads wait and held pictures stand still, the
    /// way they do for a lift.
    var liveModeActive = false

    /// The end of live mode, the lift's re-hide tail: the assertion is
    /// already back (`engine.holdLift(false)`); once the bar beneath has
    /// come to rest under `cover` the held pictures go up and it lifts.
    func endLive(covers: [ConcealGhostOverlay.GhostSet]) async {
        liftEnding = true
        liftEndGeneration += 1
        let generation = liftEndGeneration
        defer {
            if generation == liftEndGeneration {
                liftEnding = false
                appState?.liftSettled()
            }
        }
        guard let appState else { for cover in covers { cover.dismiss() }; return }
        let started = Date()
        await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
        let deadline = Date().addingTimeInterval(AppTiming.clockBlinkCoverDeadline)
        while Date() < deadline, await appState.engine.concealedItemsStillVisible() {
            try? await Task.sleep(for: .milliseconds(60))
        }
        let gone = Int(-started.timeIntervalSinceNow * 1000)
        try? await Task.sleep(for: .seconds(AppTiming.exitCoverHold))
        await appState.waitUntilQuiesced(interval: 0.15, deadline: 1, poll: .milliseconds(30))
        await hold(appState.barsKeptConcealed)
        for cover in covers { cover.dismiss() }
        PelmetLog.log("livemirror: exit cover \(covers.map(\.ids).joined(separator: " ") ) down — concealed gone at \(gone)ms, lifted at \(Int(-started.timeIntervalSinceNow * 1000))ms")
    }

    /// From the conceal or narrow that ends a lift until the bar beneath
    /// has come to rest (`endLift`), cover or not.
    private var liftEnding = false

    /// The concealed bar as the click found it: what the re-hide shows while
    /// the agent takes the pills and the extras back beneath (`beginLiftCover`).
    private var liftPicture: [ConcealGhostOverlay.BarSnapshot] = []
    /// Up from the conceal that ends a lift until the bar beneath has
    /// settled. Held pictures don't refresh under it (`refreshHeld`), nor
    /// is the idle picture taken: it would film the cover.
    private var liftCover: ConcealGhostOverlay.GhostSet?

    /// A picture of the concealed bar, kept before a lift moves anything.
    /// The idle picture when it serves, no capture; concealed, else one now,
    /// at the click (it costs the lift its length). Out already (a hover has
    /// the bar), only the idle picture can show the conceal, its own items
    /// read as the conceal will leave them, not as the reveal has them.
    func keepLiftPicture() async {
        let started = Date()
        liftPicture = []
        guard let appState else { return }
        let concealed = appState.currentRevealedSections.isEmpty
        backdropMayHaveChanged()
        let idle = freshEmptyBarSnapshots(cropped: false)
        let ownSame = revealCoverOwnBar == appState.ownBarSignature
        if !idle.isEmpty, ownSame || !concealed {
            liftPicture = idle
            PelmetLog.log("liveactivity: re-hide picture — the idle one\(ownSame ? "" : " (own items read revealed)"), no capture")
            return
        }
        guard concealed, let rect = precaptureRect else {
            PelmetLog.log("liveactivity: re-hide picture — none (\(concealed ? "no bar geometry" : "the bar is out, no idle picture")), the re-hide goes uncovered")
            return
        }
        // The lift brings the system extras and the pills in on the left
        // of the visible ones: room for them past the idle picture's edge.
        let wide = CGRect(x: rect.minX - AppTiming.liftPictureLeftRoom, y: rect.minY,
                          width: rect.width + AppTiming.liftPictureLeftRoom, height: rect.height)
        liftPicture = await ConcealGhostOverlay.snapshotSet(of: wide)
        PelmetLog.log("liveactivity: re-hide picture — captured \(Int(wide.minX))..\(Int(wide.maxX))\(idle.isEmpty ? "" : " (the idle one shows other own items)") in \(Int(-started.timeIntervalSinceNow * 1000))ms")
    }

    /// The conceal that ends a lift: the kept picture goes up over the bar
    /// first, from its left end to the clock, so the bar reads concealed
    /// in one frame, and the agent's reflow (the pills and extras leaving,
    /// the icons sliding back, held pictures retaken, own items coming and
    /// going) runs beneath it. `endLift` takes it down at rest.
    private func beginLiftCover() -> ConcealGhostOverlay.GhostSet? {
        let picture = liftPicture
        liftPicture = []
        guard !picture.isEmpty else {
            PelmetLog.log("liveactivity: re-hide uncovered — no picture kept")
            return nil
        }
        // Each display's picture to its own span, never over the clock: the
        // picture can be minutes old.
        let primaryMaxX = primaryMaxX
        let pad = ConcealGhostOverlay.capturePadding
        let clockEnd = barCoverGeometry().map { Self.coverEnd(anchorMinX: $0.anchorMinX) }
        let shots = picture.compactMap { shot -> ConcealGhostOverlay.BarSnapshot? in
            guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(shot.windowFrame) }) else { return nil }
            let shift = screen.frame.maxX - primaryMaxX
            let left = shot.windowFrame.minX - shift + pad + 1
            let right = min(shot.windowFrame.maxX - shift - pad - 1, clockEnd ?? .greatestFiniteMagnitude)
            return right > left ? ConcealGhostOverlay.cropped([shot], toPrimaryX: left...right).first : nil
        }
        guard let cover = ConcealGhostOverlay.begin(from: shots, safety: AppTiming.liftCoverSafety) else {
            PelmetLog.log("liveactivity: re-hide uncovered — the picture won't crop to the bar")
            return nil
        }
        liftCover = cover
        let spans = shots.map { "\(Int($0.windowFrame.minX))..\(Int($0.windowFrame.maxX))" }.joined(separator: " ")
        // The lifted bar reaching past the picture's left end shows that
        // much of the re-hide.
        let primaryShot = shots.first { NSScreen.screens.first?.frame.intersects($0.windowFrame) == true }
        let leftmost = appState?.snapshot?.items.compactMap(\.frame)
            .filter { MenuBarGeometry.isInPrimaryBand($0, primaryMaxX: primaryMaxX) }.map(\.minX).min()
        let short = primaryShot.flatMap { shot in leftmost.map { Int(shot.windowFrame.minX - $0) } }.flatMap { $0 > 0 ? $0 : nil }
        PelmetLog.log("liveactivity: re-hide cover \(cover.ids) up \(spans)\(short.map { ", \($0)pt short of the lifted bar's left end" } ?? "")")
        return cover
    }

    /// The conceal or narrow that ends a lift starts here, before anything
    /// moves: the cover goes up when a picture was kept. Called with the
    /// lift's state as the request found it.
    private func beginLiftEnd(_ endsLift: Bool) -> ConcealGhostOverlay.GhostSet? {
        guard endsLift else { return nil }
        liftEnding = true
        liftEndGeneration += 1
        return beginLiftCover()
    }
    /// Only the latest lift's end clears `liftEnding`.
    private var liftEndGeneration = 0

    /// Once the bar beneath has come to rest: the swap quiet, the concealed
    /// items out of the tree, the agent's fade run, quiet again (the own
    /// items' reflows follow the swap). The held pictures then go up on the
    /// run the bar settled to, under the cover, and it lifts.
    private func endLift(_ endsLift: Bool, cover: ConcealGhostOverlay.GhostSet?) {
        guard endsLift else { return }
        let generation = liftEndGeneration
        Task { @MainActor in
            defer {
                if generation == liftEndGeneration {
                    liftEnding = false
                    appState?.liftSettled()
                }
            }
            guard let appState else { cover?.dismiss(); liftCover = nil; return }
            let started = Date()
            await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
            let deadline = Date().addingTimeInterval(AppTiming.clockBlinkCoverDeadline)
            while Date() < deadline, await appState.engine.concealedItemsStillVisible() {
                try? await Task.sleep(for: .milliseconds(60))
            }
            let gone = Int(-started.timeIntervalSinceNow * 1000)
            try? await Task.sleep(for: .seconds(AppTiming.exitCoverHold))
            await appState.waitUntilQuiesced(interval: 0.15, deadline: 1, poll: .milliseconds(30))
            guard let cover else {
                PelmetLog.log("liveactivity: re-hide settled at \(Int(-started.timeIntervalSinceNow * 1000))ms, uncovered")
                return
            }
            if liftCover?.ids == cover.ids { liftCover = nil }
            await hold(appState.barsKeptConcealed)
            cover.dismiss()
            PelmetLog.log("liveactivity: re-hide cover \(cover.ids) down — concealed gone at \(gone)ms, lifted at \(Int(-started.timeIntervalSinceNow * 1000))ms")
        }
    }

    func performReveal(_ sections: Set<PelmetCore.Section>, trace: PerfTrace) {
        passWaiterArrived()
        Task {
            guard let appState else { return }
            let lifting = takeLiftRequest()
            await awaitPicturePass()
            await awaitPreviousLift()
            await anchorTask?.value
            if anchored {
                await appState.liveMirror.releaseForReveal()
                await performAnchoredReveal(sections, lifting: lifting, trace: trace)
                await appState.liveMirror.revealLanded()
                return
            }
            let style = appState.settings.revealAnimation
            let recipe = AnimationRecipe.recipe(for: style)
            // Two pictures make the style: the empty bar (hides the agent's
            // slide-in) and the strip as it looks revealed and at rest
            // (taken at the last reveal settle). The finished picture
            // performs the entrance over the cover; both lift once the real
            // icons are at rest beneath, which is invisible. Missing
            // pictures degrade: cover alone → the agent's slide is hidden
            // and the cover lifts with the exit-style move; nothing → the
            // agent's slide shows.
            var cover: ConcealGhostOverlay.GhostSet?
            var finished: ConcealGhostOverlay.GhostSet?
            // A wallpaper or appearance change between two mouse-ups has no
            // signal of its own: look once more before trusting the picture.
            backdropMayHaveChanged()
            await awaitCoverRetake(style: style)
            let emptyBar = freshEmptyBarSnapshots()
            await hold(appState.barsKeptConcealed)
            let coverSource = !emptyBar.isEmpty ? "precaptured" : style != .smooth ? "live capture" : "none"
            if !emptyBar.isEmpty {
                // The still shows the collapsed glyph; a hole over the
                // glyph's core lets the live chevron (flipped at the swap)
                // show through without exposing a neighbor's edge.
                cover = ConcealGhostOverlay.begin(
                    from: punchedCover(emptyBar, columns: chevronPunch.map { ($0.lowerBound + 6)...($0.upperBound - 6) }),
                    safety: AppTiming.transitionCoverSafety
                )
            } else if style != .smooth {
                cover = await ConcealGhostOverlay.begin(over: revealCoverRect, safety: AppTiming.transitionCoverSafety)
            }
            trace.mark("cover", detail: coverSource)
            lastRevealedSections = sections
            if cover != nil, sections == [.hidden], revealedStripUsable {
                var picture: [ConcealGhostOverlay.BarSnapshot]? = revealedStripSnapshot
                let shift = revealedStripShift
                if shift != 0, let then = revealedStripChevronX {
                    // Cut out at the picture's own geometry (punch and keep
                    // in its coordinates: the hidden run is everything left
                    // of the chevron as it was), then float shifted.
                    let punch = chevronPunch.map { ($0.lowerBound - shift)...($0.upperBound - shift) }
                    let keep: ClosedRange<CGFloat>? = revealedStripSnapshot.first.map { ($0.windowFrame.minX)...(then - 1) }
                    picture = cutOutPicture(revealedStripSnapshot, background: emptyBar, punch: punch, keep: keep)?
                        .map { ConcealGhostOverlay.BarSnapshot(image: $0.image, windowFrame: $0.windowFrame.offsetBy(dx: shift, dy: 0), takenAt: $0.takenAt) }
                    PelmetLog.log("finished: bar moved since the picture (chevron \(then) → \(then + shift)) — \(picture == nil ? "cut-out failed, cover only" : "icons cut out and shifted \(Int(shift))pt")")
                } else if recipe.entrance.needsCutOut || revealedStripCutOut {
                    // Against the empty bar the picture was taken over: the
                    // fresh cover when nothing moved (and for the boot
                    // picture), the kept one when the backdrop changed
                    // since (see backdropMayHaveChanged).
                    picture = cutOutPicture(
                        revealedStripSnapshot, background: revealedStripBackground.isEmpty ? emptyBar : revealedStripBackground,
                        punch: chevronPunch(clearingFrom: lastConcealedStripRect?.maxX),
                        keep: revealedStripKeep ?? entranceKeep
                    )
                    if revealedStripCutOut {
                        PelmetLog.log("finished: \(picture == nil ? "cut-out failed, cover only" : "cut out over the fresh cover")\(revealedStripKeep == nil ? "" : " (boot picture)")")
                        // A failed cut-out against a kept background won't
                        // succeed next time either: let the next settle
                        // take a fresh picture. The boot picture only
                        // lacked a cover; it waits for one.
                        if picture == nil, !revealedStripBackground.isEmpty {
                            revealedStripSnapshot = []; revealedStripBackground = []; revealedStripKeep = nil
                        }
                    }
                }
                // A held bar shows no entrance: the icons stay off it.
                if let picture = picture?.filter({ !($0.display.map(heldDisplays.contains) ?? false) }), !picture.isEmpty {
                    Self.dumpPictures(picture, label: "entrance", keep: revealedStripKeep ?? entranceKeep, punch: chevronPunch(clearingFrom: lastConcealedStripRect?.maxX))
                    let startsHidden: Bool = { if case .pop = recipe.entrance { return false } else { return true } }()
                    finished = ConcealGhostOverlay.begin(
                        from: picture, safety: AppTiming.transitionCoverSafety, startHidden: startsHidden
                    )
                    finished?.animate(recipe.entrance, entering: true)
                }
            }
            if cover != nil, finished == nil, style == .smooth {
                // No finished picture: a Smooth cover would only hide the
                // agent's slide and pop — let the slide show instead.
                cover?.dismiss()
                cover = nil
            }
            if finished != nil { trace.mark("finished") }
            if cover == nil {
                // Nothing hides the agent's slide-in: own items join the
                // layout first so it animates around them.
                await appState.preattachOwnItems(revealing: sections)
                trace.mark("preattach")
            }
            PelmetLog.log("effect reveal \(sections) → engine (anim=\(style.rawValue), cover=\(cover != nil), finished=\(finished != nil)\(lifting ? ", lifting" : ""))")
            // Live mode: its hold ends here, in the reveal's own swap.
            await appState.liveMirror.releaseForReveal()
            await engine.reveal(sections, liftingAssertion: lifting)
            trace.mark("engine")
            trace.note(await engine.lastConvergeTiming)
            let settled = await engine.snapshot()
            appState.updateSnapshot(settled)
            appState.recordDrawnOrder(settled, revealed: sections)
            await appState.liveMirror.revealLanded()
            if let cover {
                // Hold until the engine is swap-quiet (under rapid hover
                // cycles the real swap can land AFTER the settle report)
                // AND until the agent's slide-in and the separators' attach
                // reflow are over — lifting on swap-quiet alone showed the
                // hidden icons jump a few points as the bar finished
                // settling beneath the picture (Gab, 2026-09-08).
                let liftAt = Date().addingTimeInterval(AppTiming.entranceCoverHold)
                liftsInFlight += 1
                Task { @MainActor in
                    await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
                    let remaining = liftAt.timeIntervalSinceNow
                    if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                    if let finished {
                        finished.dismiss()
                        cover.dismiss()
                    } else if case .fade(let duration) = recipe.exit {
                        cover.fadeOut(duration: duration)
                        try? await Task.sleep(for: .seconds(duration))
                    } else {
                        cover.dismiss()
                    }
                    liftsInFlight -= 1
                    trace.finish("lift")
                }
            }
            PelmetLog.log("effect reveal settled")
            onRevealSettled?()
            trace.mark("settled")
            if cover == nil { trace.finish("uncovered") }
            // A lifted strip, the pills and extras in it, is no picture of
            // the next reveal.
            if !lifting { scheduleRevealedStripPrecapture() }
        }
    }

    /// A revealed bar keeps only `sections` out: the others go back in one
    /// swap, under no cover (the agent's own exit animates them, as a
    /// conceal does), and Pelmet's extras follow inside it through the
    /// companion. Settles like a reveal of `sections`.
    func performNarrow(_ sections: Set<PelmetCore.Section>, trace: PerfTrace) {
        passWaiterArrived()
        liftRequestedAt = nil
        let endsLift = lifted
        lifted = false
        Task {
            guard let appState else { return }
            await awaitPicturePass()
            await awaitPreviousLift()
            let liftCover = beginLiftEnd(endsLift)
            lastRevealedSections = sections
            PelmetLog.log("effect narrow to \(sections.map(\.rawValue).sorted()) → engine")
            await engine.narrowReveal(to: sections)
            trace.mark("engine")
            trace.note(await engine.lastConvergeTiming)
            let settled = await engine.snapshot()
            appState.updateSnapshot(settled)
            appState.recordDrawnOrder(settled, revealed: sections)
            PelmetLog.log("effect narrow settled")
            endLift(endsLift, cover: liftCover)
            onRevealSettled?()
            trace.mark("settled")
            trace.finish("uncovered")
            if !endsLift { scheduleRevealedStripPrecapture() }
        }
    }

    /// `released`: icons Show in Menu Bar had out on their own. They go back
    /// in the same swap, and the hold they put on the idle picture ends here.
    func performConceal(trace: PerfTrace, releasing released: Set<ItemID> = []) {
        liftRequestedAt = nil
        let endsLift = lifted
        lifted = false
        Task {
            guard let appState else { return }
            await awaitPreviousLift()
            await anchorTask?.value
            let liftCover = beginLiftEnd(endsLift)
            if anchored {
                await performAnchoredConceal(trace: trace, releasing: released)
                endLift(endsLift, cover: liftCover)
                return
            }
            let style = appState.settings.revealAnimation
            let recipe = AnimationRecipe.recipe(for: style)
            // Mirror of the reveal: the empty-bar picture over the strip
            // hides the agent's own fade, and a live capture of the icons
            // (opaque for a fade, cut out for a slide) performs the exit
            // from the moment the swap lands. Nothing to capture → the
            // agent's fade shows as is.
            let stripRect = await concealStripFrames()
            trace.mark("strip", detail: await engine.restSnapshot == nil ? "walked" : "mirror")
            rememberStrip(stripRect)
            // A reveal shorter than the settle precapture (~1s) never got
            // its finished picture, and every reveal after paid the
            // cover-only path — 0.6s from the click to the icons on each
            // toggle (#35). The strip is still up and at rest: take it now.
            if lastRevealedSections == [.hidden], released.isEmpty, let why = revealedStripProblem {
                await takeRevealedStripPicture(reason: "conceal (\(why))")
            }
            let emptyBar = freshEmptyBarSnapshots()
            var cover: ConcealGhostOverlay.GhostSet?
            var strip: ConcealGhostOverlay.GhostSet?
            // No chevron hole on the way out: the empty-bar still already
            // shows the collapsed glyph, and on a bar where the chevron
            // shifts as Pelmet's extras collapse the hole ended up over the
            // last hidden icon, showing a sliver of it fading (Gab).
            let emptyCover = emptyBar
            switch recipe.exit {
            case .pop:
                cover = ConcealGhostOverlay.begin(from: emptyCover, safety: AppTiming.transitionCoverSafety)
            case .fade:
                let icons = await ConcealGhostOverlay.snapshotSet(of: stripRect)
                strip = ConcealGhostOverlay.begin(from: icons, safety: AppTiming.transitionCoverSafety)
            case .slide:
                if !emptyBar.isEmpty {
                    let icons = await ConcealGhostOverlay.snapshotSet(of: stripRect)
                    if let cut = ConcealGhostOverlay.iconsOnly(icons, background: emptyBar, punch: chevronPunch(clearingFrom: stripRect?.maxX)) {
                        cover = ConcealGhostOverlay.begin(from: emptyCover, safety: AppTiming.transitionCoverSafety)
                        strip = ConcealGhostOverlay.begin(from: cut, safety: AppTiming.transitionCoverSafety)
                    }
                }
            }
            trace.mark("cover", detail: "\(emptyBar.isEmpty ? "none" : "precaptured")\(strip != nil ? ", strip captured live" : "")")
            PelmetLog.log("effect conceal → engine (anim=\(style.rawValue), cover=\(cover != nil), strip=\(strip != nil)\(released.isEmpty ? "" : ", releasing \(released.map(\.rawValue).sorted())"))")
            // Own extras shown alone are the manager's: forgotten first, so the
            // companion inside this swap hides them with the section's extras.
            let ownReleased = released.filter(appState.isOwnExtra)
            appState.forgetExtrasAlone(ownReleased)
            await engine.conceal(releasing: released.subtracting(ownReleased))
            trace.mark("engine")
            trace.note(await engine.lastConvergeTiming)
            // The strip's move starts the moment the swap has landed — the
            // real icons fade beneath an opaque picture, nothing can bounce.
            // Before the snapshot walk: that AX pass alone is ~100ms.
            strip?.animate(recipe.exit, entering: false)
            releaseHeldAfterConceal()
            appState.updateSnapshot(await engine.snapshot())
            // The empty-bar cover lifts on swap-quiet.
            if let cover {
                // The agent's own fade beneath runs ~300ms past the swap
                // (measured 2026-09-08) — lifting the cover on swap-quiet
                // alone (150ms) showed its tail. Hold for both.
                let liftAt = Date().addingTimeInterval(AppTiming.exitCoverHold)
                liftsInFlight += 1
                Task { @MainActor in
                    await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
                    let remaining = liftAt.timeIntervalSinceNow
                    if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                    cover.dismiss()
                    liftsInFlight -= 1
                    trace.finish("lift")
                }
            } else if strip != nil, case .fade(let duration) = recipe.exit {
                // Fade's exit is the strip alone: up for its duration.
                liftsInFlight += 1
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(duration))
                    liftsInFlight -= 1
                }
            }
            PelmetLog.log("effect conceal settled")
            endLift(endsLift, cover: liftCover)
            onConcealSettled?()
            trace.mark("settled")
            if cover == nil { trace.finish("uncovered") }
            if !released.isEmpty { pressEnded() }
            scheduleRevealCoverPrecapture()
        }
    }

    /// Show in Menu Bar: these icons come out on their own, their sections
    /// stay concealed. The press relay's reveal: a picture of the empty bar
    /// hides the agent's slide-in and lifts on the icon at rest, so one icon
    /// appears in its spot instead of a section sliding in. `settles`: the
    /// rehide machine is waiting on this reveal (false when the icon joins a
    /// bar that is already revealed).
    func performItemsReveal(_ keys: Set<ItemID>, settles: Bool, trace: PerfTrace) {
        passWaiterArrived()
        Task {
            guard let appState else { return }
            await awaitPicturePass()
            await awaitPreviousLift()
            // Released while this waited (a click elsewhere, a conceal): the
            // icon must not come out behind the conceal that took it back.
            let live = keys.intersection(appState.itemsInBar)
            guard !live.isEmpty else {
                PelmetLog.log("effect reveal items — released before it started, nothing to bring out\(settles ? ", settles concealed" : "")")
                if settles { onNothingRevealed?() }
                trace.finish("skipped")
                return
            }
            let cover = await beginBarCover(label: "show")
            trace.mark("cover", detail: cover == nil ? "none" : "up")
            PelmetLog.log("effect reveal items \(live.map(\.rawValue).sorted()) → engine (cover=\(cover != nil))")
            // Pelmet's own extras hide by their own visibility, so they come
            // out through their manager; the engine brings out the rest.
            let own = live.filter(appState.isOwnExtra)
            if live.count > own.count { await engine.reveal(items: live.subtracting(own)) }
            if !own.isEmpty {
                appState.showExtrasAlone(own)
                // The agent lays the attached item out within a frame.
                try? await Task.sleep(for: AppTiming.ownItemAttachLead)
            }
            // A conceal that took these while the cover was going up ran
            // before this reveal: they are out now and nobody holds them.
            let gone = live.subtracting(appState.itemsInBar)
            if !gone.isEmpty {
                let goneOwn = gone.filter(appState.isOwnExtra)
                appState.releaseExtrasAlone(goneOwn)
                if gone.count > goneOwn.count { await engine.conceal(items: gone.subtracting(goneOwn)) }
                PelmetLog.log("effect reveal items — \(gone.map(\.rawValue).sorted()) released meanwhile, put back")
            }
            trace.mark("engine")
            trace.note(await engine.lastConvergeTiming)
            appState.updateSnapshot(await engine.snapshot())
            if let cover {
                // Same hold as a section's entrance: swap-quiet, then the
                // agent's slide and the reflow beneath are over.
                let liftAt = Date().addingTimeInterval(AppTiming.entranceCoverHold)
                liftsInFlight += 1
                Task { @MainActor in
                    await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
                    let remaining = liftAt.timeIntervalSinceNow
                    if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                    cover.dismiss()
                    liftsInFlight -= 1
                    trace.finish("lift")
                }
            }
            PelmetLog.log("effect reveal items settled")
            if settles { onRevealSettled?() }
            trace.mark("settled")
            if cover == nil { trace.finish("uncovered") }
        }
    }

    /// The other half: the icons go back alone, under the empty bar's
    /// picture as the press relay puts one back. Ends the hold that
    /// `AppState.showItemInBar` put on the idle picture while they were out.
    func performItemsConceal(_ keys: Set<ItemID>, settles: Bool, trace: PerfTrace) {
        Task {
            guard let appState else { return }
            await awaitPreviousLift()
            let cover = await beginBarCover(label: "show")
            trace.mark("cover", detail: cover == nil ? "none" : "up")
            PelmetLog.log("effect conceal items \(keys.map(\.rawValue).sorted()) → engine (cover=\(cover != nil))")
            let own = keys.filter(appState.isOwnExtra)
            appState.releaseExtrasAlone(own)
            if keys.count > own.count { await engine.conceal(items: keys.subtracting(own)) }
            trace.mark("engine")
            trace.note(await engine.lastConvergeTiming)
            appState.updateSnapshot(await engine.snapshot())
            PelmetLog.log("effect conceal items settled")
            if settles { onConcealSettled?() }
            trace.mark("settled")
            if let cover {
                // Counted before the hold: a reveal asked for meanwhile waits
                // for the lift instead of capturing under the cover (#61).
                liftsInFlight += 1
                // An extra fades out on its own clock (ghost, then width): the
                // cover stays until that is over.
                if !own.isEmpty { try? await Task.sleep(for: AppTiming.ownItemFadeHold) }
                endBarCover(cover, label: "show") { [weak self] in
                    self?.liftsInFlight -= 1
                    self?.pressEnded()
                    trace.finish("lift")
                }
            } else {
                pressEnded()
                trace.finish("uncovered")
            }
        }
    }

    /// Covers a deliberate assertion drop. Two callers drop it and take it
    /// straight back: the clock blink (see AppState.clockClicked) and an
    /// adoption window (the agent refuses to attach a newly registered item
    /// while ANY assertion is held, so the only way in is to let go — #31).
    /// Until the re-acquire lands the agent slides every hidden icon in AND
    /// brings back the system extras the assertion keeps out (Now Playing
    /// lands in the visible cluster, shifting the chevron).
    /// A live picture of the bar from its leftmost item to the clock's left
    /// edge, floated before the drop, hides the whole round trip in either
    /// state — concealed or hover-revealed — since it is the bar as it
    /// looks right now. The clock stays uncovered (it never moves: the
    /// right zone is fixed) and the pre-captured empty-bar still is no use
    /// here: it stops at the strip, right where the extras reappear.
    /// Where a bar cover has to sit: from the leftmost place a dropped
    /// assertion can slide an icon into, to the clock's left edge.
    /// `beginBarCover` captures it; `scheduleRevealCoverPrecapture` widens
    /// the idle picture to hold it, so the blink can cut its cover out of
    /// that picture instead of paying a capture at the click.
    private struct BarCoverGeometry {
        let minX: CGFloat
        /// The clock's left edge: the cover runs to it. Ending at the
        /// leftmost live icon instead (tried 2026-09-22) let the visible
        /// cluster show its own change during the drop: Pelmet's own items
        /// trade places with the system's and the cluster shifts (Gab:
        /// "the icons change since the Pelmet icon goes away").
        ///
        /// Never past it: the picture can be up to 15 minutes old, and a
        /// cover over the clock showed the minute it was taken in under
        /// every blink (22:41 at 22:42, 2026-09-25). Notification Center's
        /// panel shades the live clock itself; the wipe replays its filmed
        /// trajectory in display coordinates, so the two meet at the clock.
        let anchorMinX: CGFloat
        let band: CGRect
    }

    private func barCoverGeometry() -> BarCoverGeometry? {
        let isClock: (ObservedItem) -> Bool = { $0.id.rawValue.hasSuffix("::com.apple.menuextra.clock") }
        let primaryMaxX = primaryMaxX
        guard let appState, let items = appState.snapshot?.items, !items.isEmpty,
              let clock = items.first(where: isClock)?.frame,
              case let frames = items.compactMap(\.frame).filter({ MenuBarGeometry.isInPrimaryBand($0, primaryMaxX: primaryMaxX) }),
              let leftmost = frames.map(\.minX).min(),
              let band = lastConcealedStripRect ?? frames.first
        else { return nil }
        // Whatever the assertion still hides slides in to the LEFT of the
        // leftmost live icon when it drops. Concealed, that is the hidden
        // section and `revealCoverRect` already spans it; revealed (the
        // editor holds the bar, a hover), it is the always-hidden icons
        // and the system extras, which no strip rect budgets for — the
        // blink flashed every icon with Settings open (Gab, 2026-09-19).
        // Budget the concealed count in; the capture clamps to the notch
        // and the display edge, and a wider picture of static bar is free.
        let concealedGrowth = CGFloat(appState.snapshot?.concealed.count ?? 0) * 40
        let minX = min(leftmost, revealCoverRect?.minX ?? leftmost) - 24 - concealedGrowth
        return BarCoverGeometry(minX: minX, anchorMinX: clock.minX, band: band)
    }

    /// Where a cover anchored on a clock at `anchorMinX` ends.
    private static func coverEnd(anchorMinX: CGFloat) -> CGFloat { anchorMinX - 2 - ConcealGhostOverlay.capturePadding }

    /// The capture pads 6pt past the rect on both sides (continuous
    /// background); the right edge must land short of the clock AFTER
    /// that padding or the picture eats the date's first letter.
    private func barCoverRect(_ geometry: BarCoverGeometry, anchorMinX: CGFloat? = nil) -> CGRect {
        let maxX = Self.coverEnd(anchorMinX: anchorMinX ?? geometry.anchorMinX)
        return CGRect(
            x: geometry.minX, y: geometry.band.minY,
            width: maxX - geometry.minX, height: geometry.band.height
        )
    }

    /// The blink cover and what it is made of, so the entrance can swap it
    /// for the under-panel picture once the panel has slid in.
    final class BlinkCover {
        fileprivate(set) var current: ConcealGhostOverlay.GhostSet
        /// Covers kept underneath the current one for the blink's life:
        /// the under-panel picture can start further right than the bare
        /// one (taken when the strip was shorter), and dropping the bare
        /// cover uncovered the hidden icons on its left (Gab, 17:24).
        fileprivate var beneath: [ConcealGhostOverlay.GhostSet] = []
        fileprivate let span: ClosedRange<CGFloat>
        fileprivate let safety: TimeInterval
        /// What the bare cover shows: the stand-in under-panel still is
        /// made from it when no real one exists yet.
        fileprivate var pictures: [ConcealGhostOverlay.BarSnapshot] = []
        /// Set once lifted: a swap scheduled before the blink was refused
        /// must not raise a fresh picture on a cover nobody holds (#52).
        private(set) var dismissed = false
        fileprivate init(_ cover: ConcealGhostOverlay.GhostSet, span: ClosedRange<CGFloat>, safety: TimeInterval, pictures: [ConcealGhostOverlay.BarSnapshot] = []) {
            current = cover; self.span = span; self.safety = safety; self.pictures = pictures
        }
        /// Every cover this blink raised, for the log.
        var ids: String { (beneath + [current]).map(\.ids).joined(separator: " ") }
        /// Keeps the covers' safety fade at least `seconds` from now.
        func keepUp(for seconds: TimeInterval) {
            current.keepUp(for: seconds)
            for cover in beneath { cover.keepUp(for: seconds) }
        }
        func dismiss() {
            dismissed = true
            current.dismiss()
            for cover in beneath { cover.dismiss() }
        }
    }

    func beginBarCover(
        label: String = "clock",
        safety: TimeInterval = AppTiming.transitionCoverSafety
    ) async -> BlinkCover? {
        guard let appState, let geometry = barCoverGeometry() else { return nil }
        let isClock: (ObservedItem) -> Bool = { $0.id.rawValue.hasSuffix("::com.apple.menuextra.clock") }
        func liveAnchor(_ snap: EngineSnapshot) -> CGFloat? { snap.items.first(where: isClock)?.frame?.minX }
        func rect(anchorMinX: CGFloat) -> CGRect { barCoverRect(geometry, anchorMinX: anchorMinX) }
        let started = Date()
        // Debug: the blink with no cover at all, to film the real panel.
        if label == "clock", UserDefaults.standard.bool(forKey: "pelmet.debug.blinkNoCover") {
            PelmetLog.log("clock: debug — no cover")
            return nil
        }
        var spanEnd = Self.coverEnd(anchorMinX: geometry.anchorMinX)
        var span = geometry.minX...spanEnd
        // The picture the idle pre-capture already holds spans this cover
        // (scheduleRevealCoverPrecapture widens it to), so cut the cover
        // out of it and take no picture at all. That is the whole point:
        // a capture here lights the screen-capture indicator at the moment
        // of the click and costs the walks below (#45, #46). Only while the
        // bar is concealed — the picture is of the empty bar, and a
        // hover-revealed bar does not look like it.
        backdropMayHaveChanged()
        if appState.currentRevealedSections.isEmpty {
            var whole = freshEmptyBarSnapshots(cropped: false)
            // The backdrop signature can't see Pelmet's own items, and this
            // cover spans them: a picture of other own items shows the old
            // bar. Drop it, so the retake after the panel (or on the next
            // approach) replaces it: kept, every click after paid a capture
            // (five in a row, 2026-10-02).
            if !whole.isEmpty, revealCoverOwnBar != appState.ownBarSignature {
                PelmetLog.log("\(label): idle picture shows other own items, capturing")
                whole = []
                revealCoverSnapshot = []
                revealCoverWanted = true
                parkedCover = nil
            }
            // Right after the panel has left, the clock sits 3pt right of
            // rest for a moment; a picture that short at the clock end
            // still serves (the cover ends in bare bar before the clock).
            if let last = whole.first?.windowFrame.maxX {
                let end = last - ConcealGhostOverlay.capturePadding
                if end < spanEnd, spanEnd - end <= 4 { spanEnd = end; span = geometry.minX...spanEnd }
            }
            let reusable = ConcealGhostOverlay.cropped(whole, toPrimaryX: span)
            if reusable.isEmpty, !whole.isEmpty {
                let have = whole.first.map { "\(Int($0.windowFrame.minX))..\(Int($0.windowFrame.maxX))" } ?? "none"
                PelmetLog.log("\(label): idle picture \(have) unusable for \(Int(span.lowerBound))..\(Int(span.upperBound)), capturing")
            }
            if let cover = ConcealGhostOverlay.begin(from: reusable, safety: safety) {
                PelmetLog.log("\(label): cover up from the idle picture, no capture — ready in \(Int(-started.timeIntervalSinceNow * 1000))ms")
                return BlinkCover(cover, span: span, safety: safety, pictures: reusable)
            }
        }
        // The capture itself lights the screen-capture indicator at the
        // bar's right end and the whole cluster shifts left to make room
        // (8pt, 2026-09-14; 3pt on 2026-09-16) — the first picture is stale
        // the moment it exists, and the anchor slid under the cover's edge.
        // Walk again until it has moved and retake the picture, so cover
        // and bar agree for the cover's life. Not when the indicator is
        // already lit from a recent picture: the bar sat shifted before
        // this capture, nothing will move, and the walks were pure delay.
        let indicatorLit = ConcealGhostOverlay.captureIndicatorLit
        var snaps = await ConcealGhostOverlay.snapshotSet(of: rect(anchorMinX: geometry.anchorMinX))
        guard !snaps.isEmpty else {
            PelmetLog.log("\(label): cover none — no picture, ready in \(Int(-started.timeIntervalSinceNow * 1000))ms")
            return nil
        }
        var anchorNow = geometry.anchorMinX
        var walks = 0
        while !indicatorLit, walks < 2 {
            walks += 1
            guard let now = liveAnchor(await appState.engine.freshSnapshot()) else { break }
            if now != geometry.anchorMinX { anchorNow = now; break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        if anchorNow != geometry.anchorMinX {
            snaps = await ConcealGhostOverlay.snapshotSet(of: rect(anchorMinX: anchorNow))
        }
        let cover = ConcealGhostOverlay.begin(from: snaps, safety: safety)
        let end = Self.coverEnd(anchorMinX: anchorNow)
        PelmetLog.log("\(label): cover \(cover == nil ? "none" : "up") \(Int(geometry.minX))..\(Int(end)) anchor \(Int(geometry.anchorMinX))→\(Int(anchorNow)) after \(walks) walk(s)\(indicatorLit ? ", indicator lit" : ""), ready in \(Int(-started.timeIntervalSinceNow * 1000))ms")
        return cover.map { BlinkCover($0, span: geometry.minX...end, safety: safety, pictures: snaps) }
    }

    /// Entrance blink, as Notification Center's panel slides in: the
    /// picture this cover shows (the bar as it is at this click) with the
    /// panel's measured shade over it, wiped in from the right on the
    /// panel's own trajectory. Always the click's own picture: a kept
    /// still of the bar under the panel painted over any icon that had
    /// changed since (Gab, 2026-09-22 18:00), and refreshing it cost a
    /// capture at every exit click.
    func swapBlinkCoverUnderPanel(_ cover: BlinkCover) {
        guard !cover.dismissed else {
            PelmetLog.log("clock: cover \(cover.ids) already down, no shaded picture")
            return
        }
        guard !cover.pictures.isEmpty, let shaded = ConcealGhostOverlay.begin(from: cover.pictures, safety: cover.safety) else {
            PelmetLog.log("clock: no picture to shade, bare cover stays")
            return
        }
        shaded.addPanelShade()
        wipe(shaded, over: cover, what: "shaded picture")
    }

    private func wipe(_ under: ConcealGhostOverlay.GhostSet, over cover: BlinkCover, what: String) {
        cover.beneath.append(cover.current)
        cover.current = under
        // The panel's own trajectory, frame by frame (inset of its leading
        // edge from the display's right edge at each 1/60s), from the
        // moment the relay's click is up. Overridable for tuning:
        // `pelmet.wipe.insets` (points), `pelmet.wipe.delayMs`, `pelmet.wipe.edge`.
        let defaults = UserDefaults.standard
        let insets = (defaults.array(forKey: "pelmet.wipe.insets") as? [Double]).map { $0.map { CGFloat($0) } } ?? AppTiming.panelEntranceInsets
        let delay = (defaults.object(forKey: "pelmet.wipe.delayMs") as? Double).map { $0 / 1000 } ?? AppTiming.panelEntranceDelay
        let edge = (defaults.object(forKey: "pelmet.wipe.edge") as? Double).map { CGFloat($0) } ?? AppTiming.panelEdgeSoftness
        under.wipeInFromRight(insets: insets, frame: 1.0 / 60, delay: delay, edge: edge)
        PelmetLog.log("clock: \(what) wiping in over the cover (\(insets.count) frames, delay \(Int(delay * 1000))ms)")
    }


    /// Lift the blink cover once the re-acquire has taken beneath it. Swap-
    /// quiet is not enough: the agent finishes the drop's reveal slide
    /// before it applies the re-acquire, so the concealed items were still
    /// fading out when a hold-only lift came (Gab, 2026-09-14: "all apps at
    /// the very end"). Poll a fresh AX walk until the concealed items have
    /// left the tree, then hold for the agent's fade.
    /// `then` runs once the cover is down (an item press ends its hold on
    /// the idle picture there).
    func endBarCover(_ cover: BlinkCover, label: String = "clock", then: (@MainActor () -> Void)? = nil) {
        Task { @MainActor in
            defer { then?() }
            guard let appState else { cover.dismiss(); return }
            let started = Date()
            await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
            let deadline = Date().addingTimeInterval(AppTiming.clockBlinkCoverDeadline)
            while Date() < deadline, await appState.engine.concealedItemsStillVisible() {
                try? await Task.sleep(for: .milliseconds(60))
            }
            let gone = Int(-started.timeIntervalSinceNow * 1000)
            try? await Task.sleep(for: .seconds(AppTiming.clockBlinkLiftHold))
            cover.dismiss()
            PelmetLog.log("\(label): cover \(cover.ids) down — concealed gone at \(gone)ms, lifted at \(Int(-started.timeIntervalSinceNow * 1000))ms")
        }
    }

    /// The empty-bar capture from the last conceal settle, if it is recent
    /// enough to stand in for the bar as it looks now (static wallpaper).
    ///
    /// The stored picture spans `precaptureRect` — the reveal cover widened
    /// to the blink's footprint — so the reveal path takes it `cropped`
    /// back to its own rect and the blink cuts its own cover out of it.
    private func freshEmptyBarSnapshots(cropped: Bool = true) -> [ConcealGhostOverlay.BarSnapshot] {
        guard let first = revealCoverSnapshot.first,
              Date().timeIntervalSince(first.takenAt) < AppTiming.revealCoverFreshness
        else { return [] }
        guard revealCoverActiveDisplay == appState?.lastMouseDownDisplay else {
            PelmetLog.log("cover: picture from another active display (\(revealCoverActiveDisplay ?? 0) → \(appState?.lastMouseDownDisplay ?? 0)), not used")
            return []
        }
        // The panel is not in the backdrop signature: a picture taken under
        // it is only true while it is open, and the other way round.
        guard revealCoverUnderPanel == ClockClickRelay.notificationCenterIsOpen() else {
            PelmetLog.log("cover: picture taken with the panel \(revealCoverUnderPanel ? "open" : "closed"), not used")
            return []
        }
        guard cropped, let want = revealCoverRect, want != precaptureRect else { return revealCoverSnapshot }
        let narrowed = ConcealGhostOverlay.cropped(revealCoverSnapshot, toPrimaryX: want.minX...want.maxX)
        return narrowed.isEmpty ? revealCoverSnapshot : narrowed
    }

    // MARK: - Held bars (#88)

    /// The run a held picture covers, primary-band x: the hidden items —
    /// from the widest strip measured, so the always-hidden ones are in it
    /// too, less 16pt for the capture indicator's shift (3–16pt for ~3s
    /// past any capture) — up to the chevron, which the run ends against
    /// (the strip seeded at boot ended 85pt short of it, and the first
    /// reveal showed the last icons on a held bar: live test, 2026-10-19).
    /// The crop pads by `capturePadding` and lands on that edge, short of
    /// the chevron's glyph even shifted. Never past it either: a strip taken
    /// with the chevron at 1605 held the bar to 1591 once Camera & Mic and
    /// Media Controls pushed it to 1537, and the picture hid the chevron
    /// (2026-10-23). Anchored, the hidden items are out and read live.
    private var heldRunNow: ClosedRange<CGFloat>? {
        var strip = lastConcealedStripRect
        if anchored, let live = liveHiddenRun { strip = strip.map { $0.union(live) } ?? live }
        guard let strip else { return nil }
        let right = (primaryChevronMinX ?? strip.maxX) - ConcealGhostOverlay.capturePadding
        let left = min(strip.minX, widestStripMinX ?? strip.minX) - 16
        return right - left > 8 ? left...right : nil
    }

    /// The items of the sections out while anchored, on the primary band,
    /// left of the chevron: the chevron and the visible items stay in sight.
    private var liveHiddenRun: CGRect? {
        guard let appState, let items = appState.snapshot?.items else { return nil }
        let primaryMaxX = primaryMaxX
        let out = anchoredSections
        let chevronMinX = primaryChevronMinX ?? .greatestFiniteMagnitude
        return items.reduce(nil as CGRect?) { run, item in
            guard item.id != AppState.chevronItemID, let frame = item.frame, frame.maxX <= chevronMinX + 1,
                  MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX),
                  out.contains(appState.settings.sectionModel.section(of: item.id))
                    || placingSectionless && MenuBarPolicy.isSectionlessSystemIcon(item.id) else { return run }
            return run.map { $0.union(frame) } ?? frame
        }
    }

    /// The chevron on the primary bar: the snapshot can carry its copy on
    /// another display's bar (x 4995 on the LG, live 2026-10-19), and a run
    /// up to that spanned every display.
    private var primaryChevronMinX: CGFloat? {
        let primaryMaxX = primaryMaxX
        return appState?.snapshot?.items.lazy
            .filter { $0.id == AppState.chevronItemID }
            .compactMap(\.frame)
            .first { MenuBarGeometry.isInPrimaryBand($0, primaryMaxX: primaryMaxX) }?.minX
    }

    private func heldBackdrop(_ run: ClosedRange<CGFloat>, in windows: [[String: Any]]?) -> [Int] {
        ConcealGhostOverlay.backdropSignature(
            of: CGRect(x: run.lowerBound, y: 0, width: run.upperBound - run.lowerBound, height: 1), in: windows)
            + ConcealGhostOverlay.surfaceSignature()
    }

    /// The kept pictures still serve: they cover `run`'s items (a run that
    /// only shrank, or slid within the 16pt pad, keeps them — retaking on
    /// every capture indicator shift would light it again, and again) over
    /// the same backdrop.
    private func heldShown(for wanted: ClosedRange<CGFloat>) -> ClosedRange<CGFloat>? {
        guard let kept = heldPicturesRun else { return nil }
        let left = max(kept.lowerBound, wanted.lowerBound).rounded(), right = min(kept.upperBound, wanted.upperBound).rounded()
        return right - left > 8 ? left...right : nil
    }

    private func heldPicturesServe(_ run: ClosedRange<CGFloat>, in windows: [[String: Any]]?) -> Bool {
        guard let kept = heldPicturesRun else { return false }
        return kept.lowerBound <= run.lowerBound + 16 && kept.upperBound >= run.upperBound - 1
            && heldPicturesBackdrop == heldBackdrop(kept, in: windows)
    }

    /// Keep exactly `displays` looking concealed. The ones up stay; the
    /// others go up from the kept pictures, else the idle picture of the
    /// empty bar, else a capture of the bare bar (`snapshotSet(bare:)`,
    /// true with the icons out too), and `enter` says how one goes up over
    /// icons already out (a conceal while anchored). The rest lift with
    /// `lift`. The run is bare glass on a concealed bar, the same whichever
    /// display is active — dimming touches only glyphs (frames 2026-10-19,
    /// max diff 3 bright vs dim) — so a click on another bar while it is
    /// held leaves the picture true.
    private func hold(
        _ displays: Set<CGDirectDisplayID>, lift: AnimationRecipe.Move = .pop, enter: AnimationRecipe.Move = .pop
    ) async {
        heldWant = displays
        guard let wantedRun = heldRunNow, !displays.isEmpty else {
            for (id, cover) in held {
                Self.lift(cover, lift)
                PelmetLog.log("held: lifted \(cover.ids) on display \(id)")
            }
            held = [:]
            heldShownRun = nil
            heldShownHoles = []
            return
        }
        for id in heldDisplays.subtracting(displays) {
            guard let cover = held.removeValue(forKey: id) else { continue }
            Self.lift(cover, lift)
            PelmetLog.log("held: lifted \(cover.ids) on display \(id)")
        }
        let windows = ConcealGhostOverlay.onScreenWindows()
        if !heldPicturesServe(wantedRun, in: windows) {
            heldPictures = [:]
            heldPicturesRun = wantedRun
            heldPicturesBackdrop = heldBackdrop(wantedRun, in: windows)
        }
        guard let run = heldPicturesRun, let shown = heldShown(for: wantedRun) else { return }
        let holes = heldHoles(in: shown)
        // Up already over pictures that still serve: nothing to do.
        let wanted = displays.filter {
            held[$0]?.isUp != true || heldPictures[$0] == nil || heldShownRun != shown || heldShownHoles != holes
        }
        // A cover raised before the anchor (a bar reveal's 10-minute hold)
        // stays for as long as the anchor does.
        if anchored { for (_, cover) in held { cover.keepUp(for: AppTiming.anchoredBarCeiling) } }
        guard !wanted.isEmpty else { return }
        var missing = wanted.filter { heldPictures[$0] == nil }
        var source = "kept pictures"
        if !missing.isEmpty, !revealCoverSnapshot.isEmpty,
           let taken = revealCoverSnapshot.first?.takenAt, Date().timeIntervalSince(taken) < AppTiming.revealCoverFreshness,
           revealCoverBackdrop == heldPicturesBackdrop,
           revealCoverUnderPanel == ClockClickRelay.notificationCenterIsOpen() {
            let idle = revealCoverSnapshot.filter { $0.display.map(missing.contains) ?? false }
            for snap in ConcealGhostOverlay.cropped(idle, toPrimaryX: run) {
                if let id = snap.display { heldPictures[id] = snap }
            }
            source = "the idle picture"
        }
        missing = missing.filter { heldPictures[$0] == nil }
        if !missing.isEmpty {
            let rect = CGRect(x: run.lowerBound, y: 0, width: run.upperBound - run.lowerBound,
                              height: (lastConcealedStripRect ?? liveHiddenRun)?.maxY ?? 24)
            let epoch = heldDropEpoch
            heldCapturesInFlight += 1
            let shots = await ConcealGhostOverlay.snapshotSet(of: rect, displays: missing, bare: true)
            heldCapturesInFlight -= 1
            // The displays changed, or a newer hold retook for another run:
            // these pictures are of a bar that is gone, and that hold has it.
            guard epoch == heldDropEpoch, heldPicturesRun == run else {
                PelmetLog.log("held: overtaken during the capture — pictures dropped")
                return
            }
            for snap in ConcealGhostOverlay.cropped(shots, toPrimaryX: run) {
                if let id = snap.display { heldPictures[id] = snap }
            }
            source = "a capture of the bare bar"
        }
        heldShownRun = shown
        heldShownHoles = holes
        let pieces = Self.heldPieces(of: shown, holes: holes)
        for id in wanted where heldWant.contains(id) {
            guard let kept = heldPictures[id] else { continue }
            let pictures = shown == run && holes.isEmpty
                ? [kept] : pieces.compactMap { ConcealGhostOverlay.cropped([kept], toPrimaryX: $0).first }
            let entering: Bool = { if case .pop = enter { return false } else { return held[id]?.isUp != true } }()
            guard let cover = ConcealGhostOverlay.begin(
                from: pictures, safety: anchored ? AppTiming.anchoredBarCeiling : AppTiming.heldBarCeiling,
                startHidden: entering, holdsBar: true
            ) else { continue }
            if entering { cover.animate(enter, entering: true) }
            if heldPassClicks { cover.passClicks(true) }
            // Replaced in place: the new picture is up before the old goes.
            held.removeValue(forKey: id)?.dismiss()
            held[id] = cover
        }
        let edges = "strip \(lastConcealedStripRect.map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "-"), live \(liveHiddenRun.map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "-"), chevron \(primaryChevronMinX.map { "\(Int($0))" } ?? "-")"
        let inSight = holes.isEmpty ? "" : ", in sight \(holes.map { "\(Int($0.lowerBound))..\(Int($0.upperBound))" }.joined(separator: " "))"
        PelmetLog.log("held: display(s) \(wanted.sorted()) kept concealed — run \(Int(shown.lowerBound))..\(Int(shown.upperBound)) of \(Int(run.lowerBound))..\(Int(run.upperBound)) from \(source) (\(edges))\(inSight)")
    }

    /// What a held picture leaves out of its run: the icons no section
    /// holds. Nothing hides them, so neither may a picture of the bare bar:
    /// the recording pill came up at x 1337 under the held run 1016..1565,
    /// and only quitting Dimble showed it (2026-10-22). Live frames only,
    /// the native «'s phantoms left out (`ApplyPass.primaryFrames`), from a
    /// walk at rest: one 160ms after the launch swap cut a hole at
    /// 1570..1587, mid-reflow, over whatever slid past.
    private func heldHoles(in shown: ClosedRange<CGFloat>) -> [ClosedRange<CGFloat>] {
        guard !placingSectionless, let appState, let snap = appState.snapshot else { return [] }
        guard snap.itemsAtRest else { return heldShownHoles.filter { $0.overlaps(shown) } }
        return ApplyPass.primaryFrames(snap, appState: appState)
            .filter { MenuBarPolicy.isSectionlessSystemIcon($0.key) }
            .map { $0.value.minX.rounded()...$0.value.maxX.rounded() }
            .filter { $0.overlaps(shown) }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    /// `shown` less the holes, as spans `cropped` pads back out to the
    /// hole's edges: the icons either side of one stay covered.
    private static func heldPieces(of shown: ClosedRange<CGFloat>, holes: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        let pad = ConcealGhostOverlay.capturePadding
        var pieces: [ClosedRange<CGFloat>] = []
        var left = shown.lowerBound
        for hole in holes {
            let right = min(hole.lowerBound - pad, shown.upperBound)
            if right - left > 8 { pieces.append(left...right) }
            left = max(left, hole.upperBound + pad)
        }
        if shown.upperBound - left > 8 { pieces.append(left...shown.upperBound) }
        return pieces
    }

    private static func lift(_ cover: ConcealGhostOverlay.GhostSet, _ move: AnimationRecipe.Move) {
        switch move {
        case .pop: cover.dismiss()
        case .fade(let duration): cover.fadeOut(duration: duration)
        case .slide(_, let duration): cover.fadeOut(duration: min(duration, 0.3))
        }
    }

    /// A held picture comes and goes in place: a slide reads as a fade.
    private static func inPlace(_ move: AnimationRecipe.Move) -> AnimationRecipe.Move {
        if case .slide(_, let duration) = move { return .fade(min(duration, 0.3)) }
        return move
    }

    /// The conceal swap is in: the held bars lift with the conceal's own
    /// cover, once the agent's fade beneath has run. Not a lift a reveal
    /// waits for: a picture taken under it is the empty bar it shows.
    private func releaseHeldAfterConceal() {
        guard !held.isEmpty, let appState else { return }
        let liftAt = Date().addingTimeInterval(AppTiming.exitCoverHold)
        heldFadeEnds = liftAt
        Task { @MainActor in
            await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
            let remaining = liftAt.timeIntervalSinceNow
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            await hold(appState.barsKeptConcealed)
        }
    }
    /// Until then a conceal's fade runs beneath the held bars, and the
    /// re-hold after it (`releaseHeldAfterConceal`) is the one that trims.
    private var heldFadeEnds: Date?

    /// Live mode stands over the bars the anchor holds: its covers
    /// are pictures of the same bare glass, up before this is called, and
    /// the mirrors would sit beneath a held window. The held windows go;
    /// the pictures stay, so the exit's `hold` puts them back up with no
    /// capture while the live covers are still over the bar.
    func releaseHeldForLive() {
        guard !held.isEmpty else { return }
        for (_, cover) in held { cover.dismiss() }
        PelmetLog.log("held: \(held.values.map(\.ids).joined(separator: " ")) down for live mode — its covers stand in, the pictures are kept")
        held = [:]
        heldShownRun = nil
        heldShownHoles = []
    }

    /// Anchored, where the held run starts (primary band): live mode's
    /// covers reach at least this far left, the hidden icons being out.
    var heldRunLeft: CGFloat? { anchored ? heldRunNow?.lowerBound : nil }

    /// The displays changed under a hold: its pictures sit at the old
    /// geometry and would eat clicks there. Anchored, they go back up
    /// once the displays have settled (`refreshHeld`).
    func dropHeldBars(_ why: String) {
        heldDropEpoch &+= 1
        heldWant = []
        heldShownRun = nil
        heldShownHoles = []
        // Kept pictures sit at the old geometry even with none up.
        heldPictures = [:]
        heldPicturesRun = nil
        guard !held.isEmpty else { return }
        for (_, cover) in held { cover.dismiss() }
        PelmetLog.log("held: dropped \(held.values.map(\.ids).joined(separator: " ")) — \(why)")
        held = [:]
    }

    /// Something under the bar may have moved, the bar's items moved, or
    /// the displays settled: held pictures that no longer serve are retaken
    /// and swapped in place, and a missing one goes back up.
    func refreshHeld(_ why: String) {
        // A pass has the bar: its rounds take Hidden in, which reads as no
        // run and would lift every held picture (2026-10-19 17:45, the
        // hidden icons showed as the pass cover lifted). The pass re-holds
        // before its cover lifts, and its end refreshes.
        guard let appState, !passInFlight else { return }
        // A lift's re-hide cover is over the bar: what moves beneath it is
        // the reflow it hides, and it re-holds before it lifts.
        guard liftCover == nil, !liveModeActive else { return }
        // One read of the window list for every bar and the backdrop.
        var windows: [[String: Any]]?
        let want = appState.barsKeptConcealed(windows: &windows)
        guard !want.isEmpty || !held.isEmpty else { return }
        if windows == nil { windows = ConcealGhostOverlay.onScreenWindows() }
        let stale = heldRunNow.map { !heldPicturesServe($0, in: windows) } ?? true
        let shownNow = stale ? nil : heldRunNow.flatMap(heldShown(for:))
        let moved = !stale && shownNow != heldShownRun
        let holed = !stale && !moved && (shownNow.map(heldHoles(in:)) ?? []) != heldShownHoles
        guard stale || moved || holed || want != heldDisplays else { return }
        let what = stale ? "retake" : moved ? "trim" : holed ? "holes" : "re-hold"
        // The items read as gone the moment the conceal's swap lands, while
        // they still fade beneath: a trim now showed them mid-fade
        // (2026-10-29, Wi-Fi and battery flashed on the built-in as the
        // LG's « closed). Only what would uncover waits: a run that grows
        // (the « moving right as they leave) covers more at once.
        let grows = shownNow.flatMap { now in
            heldShownRun.map { now.lowerBound <= $0.lowerBound && now.upperBound >= $0.upperBound }
        } ?? false
        let uncovers = (moved && !grows) || holed || !heldDisplays.isSubset(of: want)
        if uncovers, let ends = heldFadeEnds, ends > Date() {
            PelmetLog.log("held: \(what) waits for the conceal's fade (\(Int(ends.timeIntervalSinceNow * 1000))ms) — \(why)")
            return
        }
        PelmetLog.log("held: \(what) — \(why)")
        // One at a time: a burst of item moves is one hold, then one more
        // with what the burst left.
        guard refreshInFlight == nil else { refreshAgain = true; return }
        refreshInFlight = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                refreshAgain = false
                await hold(appState.barsKeptConcealed)
            } while refreshAgain
            refreshInFlight = nil
        }
    }
    private var refreshInFlight: Task<Void, Never>?
    private var refreshAgain = false

    /// Anchored, a press clicks an item out under the press display's
    /// held picture: the picture lifts for the click (the item highlights,
    /// its menu drops from it) and goes back up once what it showed is gone.
    func unholdForPress(display: CGDirectDisplayID, at x: CGFloat) -> Bool {
        guard anchored, let run = heldShownRun, let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: { $0.directDisplayID == display }),
              run.contains(x - (screen.frame.maxX - primary.frame.maxX)),
              let cover = held.removeValue(forKey: display) else { return false }
        pressUnheld = display
        cover.dismiss()
        PelmetLog.log("held: lifted \(cover.ids) on display \(display) for a press")
        return true
    }

    func reholdAfterPress() {
        pressUnheld = nil
        guard let appState else { return }
        Task { await hold(appState.barsKeptConcealed) }
    }

    // MARK: - Anchored (#88)

    /// At rest for a picture pass: concealed, or anchored with nothing out
    /// beyond the anchor — no bar reveal under way, the panel's own reveal
    /// allowed (it leaves the bar as it rests).
    private var barRestsForPass: Bool {
        guard let appState else { return false }
        let out = appState.currentRevealedSections
        if out.isEmpty { return true }
        guard anchored, out == anchoredSections else { return false }
        return appState.panelShowsReveal || (!appState.isRevealed && !appState.isTransitioning)
    }

    /// The bar goes out for good (a display that shows all icons is
    /// connected) or back to concealing. Called on a concealed, settled bar.
    /// Where the anchor is headed: a request still queued behind another.
    var anchorTarget: Bool { pendingAnchor ?? anchored }
    private var pendingAnchor: Bool?

    func setAnchored(_ on: Bool) {
        guard on != anchorTarget, let appState else { return }
        pendingAnchor = on
        let previous = anchorTask
        anchorTask = Task { @MainActor in
            await previous?.value
            // A pass ends where it started (concealed or at the anchor):
            // turning the anchor under it would be undone by its end.
            await awaitPicturePass()
            defer { if pendingAnchor == on { pendingAnchor = nil } }
            if on {
                // Every hiding display is covered before its icons come out.
                anchored = true
                anchoredSections = [.hidden]
                let want = appState.barsKeptConcealed
                await hold(want)
                // A refresh may be capturing the same bars: wait it out.
                let by = Date().addingTimeInterval(2)
                while heldCapturesInFlight > 0, Date() < by { try? await Task.sleep(for: .milliseconds(20)) }
                // No picture, no anchor: the icons would show on a bar that
                // hides them. The pointer's display decides, as before.
                guard want.isSubset(of: heldDisplays) else {
                    anchored = false
                    anchorFailedAt = Date()
                    await hold([])
                    PelmetLog.log("anchor: no picture for display(s) \(want.subtracting(heldDisplays).sorted()) — stays concealed")
                    return
                }
                anchorFailedAt = nil
                await engine.reveal([.hidden])
                appState.updateSnapshot(await engine.snapshot())
                PelmetLog.log("anchor: on — Hidden out, held \(heldDisplays.sorted())")
            } else {
                anchored = false
                await engine.conceal()
                appState.updateSnapshot(await engine.snapshot())
                PelmetLog.log("anchor: off — concealed")
                releaseHeldAfterConceal()
                scheduleRevealCoverPrecapture()
            }
        }
    }

    /// Anchored: Hidden is out on every bar already, under the hiding
    /// displays' pictures. The deciding display's picture lifts — the
    /// icons are beneath it — and only Always Hidden takes the engine.
    private func performAnchoredReveal(_ sections: Set<PelmetCore.Section>, lifting: Bool, trace: PerfTrace) async {
        guard let appState else { return }
        let recipe = AnimationRecipe.recipe(for: appState.settings.revealAnimation)
        lastRevealedSections = sections
        if !sections.isSubset(of: anchoredSections) || lifting {
            anchoredSections.formUnion(sections)
            // The held pictures reach the widest strip: Always Hidden lands
            // under them on every bar that keeps concealed.
            await hold(appState.barsKeptConcealed)
            await engine.reveal(anchoredSections, liftingAssertion: lifting)
            trace.mark("engine")
            trace.note(await engine.lastConvergeTiming)
            appState.updateSnapshot(await engine.snapshot())
        }
        await hold(appState.barsKeptConcealed, lift: Self.inPlace(recipe.entrance))
        PelmetLog.log("effect reveal \(sections) anchored — held \(heldDisplays.sorted())")
        onRevealSettled?()
        trace.mark("settled")
        trace.finish("anchored")
    }

    /// Anchored: the deciding display's picture goes back up over the
    /// icons, still out for the displays that show all; Always Hidden
    /// goes back in one swap.
    private func performAnchoredConceal(trace: PerfTrace, releasing released: Set<ItemID>) async {
        guard let appState else { return }
        let recipe = AnimationRecipe.recipe(for: appState.settings.revealAnimation)
        await hold(appState.barsKeptConcealed, enter: Self.inPlace(recipe.exit))
        let ownReleased = released.filter(appState.isOwnExtra)
        appState.forgetExtrasAlone(ownReleased)
        let others = released.subtracting(ownReleased)
        if anchoredSections != [.hidden] || !others.isEmpty {
            if anchoredSections != [.hidden] {
                anchoredSections = [.hidden]
                await engine.narrowReveal(to: [.hidden])
            }
            if !others.isEmpty { await engine.conceal(items: others) }
            trace.mark("engine")
            // What went in fades beneath the held bars: they keep its run
            // until the fade has run, then trim to what is left.
            heldFadeEnds = Date().addingTimeInterval(AppTiming.exitCoverHold)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(AppTiming.exitCoverHold))
                self?.refreshHeld("the conceal's fade ran")
            }
            appState.updateSnapshot(await engine.snapshot())
        }
        PelmetLog.log("effect conceal anchored — held \(heldDisplays.sorted())\(released.isEmpty ? "" : ", releasing \(released.map(\.rawValue).sorted())")")
        onConcealSettled?()
        trace.mark("settled")
        trace.finish("anchored")
        if !released.isEmpty { pressEnded() }
    }

    /// The pixel passes over the pictures are pure functions of the
    /// pictures and the chevron's columns; between reveals nothing changes,
    /// and both ran on the main thread on every reveal (2026-09-21).
    /// Memoized on their inputs — a picture's `takenAt` is its identity.
    private var punchedCoverCache: (key: String, snaps: [ConcealGhostOverlay.BarSnapshot])?
    private var cutOutCache: (key: String, picture: [ConcealGhostOverlay.BarSnapshot])?

    private static func pictureKey(_ snaps: [ConcealGhostOverlay.BarSnapshot]) -> String {
        snaps.map { "\($0.takenAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
    }

    private func punchedCover(_ emptyBar: [ConcealGhostOverlay.BarSnapshot], columns: [ClosedRange<CGFloat>]) -> [ConcealGhostOverlay.BarSnapshot] {
        let key = Self.pictureKey(emptyBar) + "#" + columns.map { "\($0)" }.joined()
        if let cached = punchedCoverCache, cached.key == key { return cached.snaps }
        let snaps = ConcealGhostOverlay.clearing(emptyBar, columns: columns)
        punchedCoverCache = (key, snaps)
        return snaps
    }

    /// Debug: `defaults write app.fif7y.Pelmet pelmet.debug.dumpPictures -bool YES`
    /// writes every entrance picture to ~/Library/Logs/Dimble/pictures/ with
    /// its span, keep and punch in the log, so what slides can be compared
    /// with what the bar shows (2026-10-02: Sound missing from the slide on
    /// the external display).
    private static func dumpPictures(_ picture: [ConcealGhostOverlay.BarSnapshot], label: String, keep: ClosedRange<CGFloat>?, punch: [ClosedRange<CGFloat>]) {
        guard UserDefaults.standard.bool(forKey: "pelmet.debug.dumpPictures") else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dimble/pictures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let spans = picture.map { "\(Int($0.windowFrame.minX))..\(Int($0.windowFrame.maxX))" }.joined(separator: " ")
        PelmetLog.log("picture: \(label) \(picture.count) snap(s) [\(spans)] keep \(keep.map { "\(Int($0.lowerBound))..\(Int($0.upperBound))" } ?? "none") punch \(punch.map { "\(Int($0.lowerBound))..\(Int($0.upperBound))" }.joined(separator: ","))")
        for snap in picture {
            let url = dir.appendingPathComponent("\(stamp)_\(label)_x\(Int(snap.windowFrame.minX)).png")
            let rep = NSBitmapImageRep(cgImage: snap.image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private func cutOutPicture(
        _ strips: [ConcealGhostOverlay.BarSnapshot], background: [ConcealGhostOverlay.BarSnapshot],
        punch: [ClosedRange<CGFloat>], keep: ClosedRange<CGFloat>?
    ) -> [ConcealGhostOverlay.BarSnapshot]? {
        let key = Self.pictureKey(strips) + "/" + Self.pictureKey(background) + "#" + punch.map { "\($0)" }.joined() + "#" + (keep.map { "\($0)" } ?? "")
        if let cached = cutOutCache, cached.key == key { return cached.picture }
        guard let picture = ConcealGhostOverlay.iconsOnly(strips, background: background, punch: punch, keep: keep) else { return nil }
        cutOutCache = (key, picture)
        return picture
    }

    /// The chevron's columns, relative to the strip rect — its glyph flips
    /// between the two captures and would otherwise ride the cut-out.
    private var chevronPunch: [ClosedRange<CGFloat>] { chevronPunch(clearingFrom: nil) }

    /// The chevron's columns, never starting left of `x`: its AX frame
    /// overlaps the neighboring icon by a few points, and a punch from the
    /// frame's edge clipped that icon before it moved (Gab, Smooth exit).
    private func chevronPunch(clearingFrom x: CGFloat?) -> [ClosedRange<CGFloat>] {
        guard let chevron = appState?.snapshot?.items.first(where: { $0.id == AppState.chevronItemID })?.frame
        else { return [] }
        let lower = max(chevron.minX, x ?? -.greatestFiniteMagnitude)
        guard lower < chevron.maxX else { return [] }
        return [lower...chevron.maxX]
    }

    /// The widest strip any conceal has measured: AX lists freshly revealed
    /// items progressively, and a short measurement left the leftmost icons
    /// outside the entrance picture — they popped in at lift instead of
    /// sliding (Gab: "sometimes not all icons slide").
    private var entranceKeep: ClosedRange<CGFloat>? {
        guard let strip = lastConcealedStripRect else { return nil }
        let minX = min(strip.minX, widestStripMinX ?? strip.minX)
        return (minX - 6)...(strip.maxX + 6)
    }

    private var precaptureTask: Task<Void, Never>?
    /// Which precapture owns `precaptureInFlight`: only the latest clears it.
    private var precaptureGeneration = 0
    private var revealedPrecaptureTask: Task<Void, Never>?

    /// The strip as it looks revealed and at rest — the Instant/Fade reveal
    /// paints it at once. Taken at reveal settle; dropped when the engine
    /// reports the bar changed (an icon added, removed or reordered would
    /// paint a stale picture).
    private var revealedStripSnapshot: [ConcealGhostOverlay.BarSnapshot] = []
    /// Notification Center's panel was under the bar for the finished
    /// picture: only true while it still is, and the other way round (a
    /// picture from under the panel darkened reveals after it closed).
    private var revealedStripUnderPanel = false
    /// The empty-bar picture the finished picture sits on, kept only once
    /// the backdrop changed under both (see backdropMayHaveChanged): the
    /// reveal then cuts the icons out against it. Empty otherwise.
    private var revealedStripBackground: [ConcealGhostOverlay.BarSnapshot] = []
    /// The boot picture's hidden run (see takeBootPicture): cut out against
    /// the fresh cover, keeping these columns only. Nil for a picture of
    /// the revealed bar, which keeps `entranceKeep`.
    private var revealedStripKeep: ClosedRange<CGFloat>?
    /// The picture is icons over an empty bar it must be cut out against.
    private var revealedStripCutOut: Bool { !revealedStripBackground.isEmpty || revealedStripKeep != nil }
    /// What the last reveal showed — the state machine is already
    /// transitioning to conceal when performConceal runs.
    private var lastRevealedSections: Set<PelmetCore.Section> = []
    /// What the picture shows: the hidden section's membership and order
    /// when it was taken. A reveal only paints it while that still holds
    /// (an editor move, an adopted drag or a new app changes the picture;
    /// the conceal's own item churn does not).
    private var revealedStripSignature: [ItemID] = []
    /// The chevron's x when the picture was taken. A visible-section
    /// change (an indicator appearing, a placement drag) shifts the chevron,
    /// and a picture from before it paints the glyph at the old x next to
    /// the live one (two chevrons for a beat, #39 video at 18:45:56).
    private var revealedStripChevronX: CGFloat?
    private var liveChevronMinX: CGFloat? {
        appState?.snapshot?.items.first(where: { $0.id == AppState.chevronItemID })?.frame?.minX
    }
    /// How far the bar has moved since the picture is read off the nearest
    /// live item right of the chevron, not the chevron: with no glyph its
    /// AX frame sits on its hidden neighbour's spot in the concealed bar,
    /// 16pt from where it reads revealed, and comparing the two floated
    /// the picture 16pt off a bar that had not moved (frames, 2026-09-22:
    /// Snib cut in half, the strip jumping at lift). The neighbour stays
    /// put across a reveal and still moves with the capture indicator or
    /// an expanded «.
    private var revealedStripAnchor: (id: ItemID, minX: CGFloat)?
    private var liveAnchor: (id: ItemID, minX: CGFloat)? {
        guard let items = appState?.snapshot?.items,
              let chevron = items.first(where: { $0.id == AppState.chevronItemID })?.frame else { return nil }
        let primaryMaxX = primaryMaxX
        return items.compactMap { item -> (id: ItemID, minX: CGFloat)? in
            guard item.id != AppState.chevronItemID, let frame = item.frame,
                  frame.minX >= chevron.maxX - 1, MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX)
            else { return nil }
            return (item.id, frame.minX)
        }.min { $0.minX < $1.minX }
    }
    /// The anchor's x now, and how far it moved since the picture. An
    /// anchor gone from the bar (a media control that stopped) falls back
    /// to the chevron, which does read a real move then.
    private var revealedStripMove: (then: CGFloat, now: CGFloat)? {
        if let anchor = revealedStripAnchor,
           let now = appState?.snapshot?.items.first(where: { $0.id == anchor.id })?.frame?.minX {
            return (anchor.minX, now)
        }
        guard let then = revealedStripChevronX, let now = liveChevronMinX else { return nil }
        return (then, now)
    }

    private var hiddenSectionSignature: [ItemID] {
        guard let model = appState?.settings.sectionModel else { return [] }
        let ordered = model.order[.hidden] ?? []
        let rest = model.assignments.filter { $0.value == .hidden }.map(\.key).filter { !ordered.contains($0) }
        return ordered + rest.sorted { $0.rawValue < $1.rawValue }
    }

    private var revealedStripUsable: Bool {
        guard let why = revealedStripProblem else { return true }
        PelmetLog.log("finished: \(why)")
        return false
    }

    /// Why the finished picture can't be painted, nil when it can.
    private var revealedStripProblem: String? {
        guard let first = revealedStripSnapshot.first else { return "no picture" }
        guard Date().timeIntervalSince(first.takenAt) < AppTiming.revealedStripFreshness else { return "picture stale" }
        guard revealedStripSignature == hiddenSectionSignature else {
            return "hidden section changed since the picture — was \(revealedStripSignature.map(\.rawValue)) now \(hiddenSectionSignature.map(\.rawValue))"
        }
        guard revealedStripActiveDisplay == appState?.lastMouseDownDisplay else { return "picture from another active display" }
        guard revealedStripUnderPanel == ClockClickRelay.notificationCenterIsOpen() else {
            return "picture taken with the panel \(revealedStripUnderPanel ? "open" : "closed")"
        }
        if let (then, now) = revealedStripMove, abs(then - now) > 1, freshEmptyBarSnapshots().isEmpty {
            return "bar moved since the picture (\(then) → \(now)) and no cover to cut out against"
        }
        return nil
    }

    /// How far the whole cluster has moved since the picture: the capture
    /// indicator shifts it ~16pt for ~3s after any capture, an extra
    /// showing or hiding shifts it by its width. The wallpaper stays put,
    /// so the picture still cuts out cleanly against the empty-bar cover
    /// at its own geometry; the icons are then floated shifted by this
    /// much and land where the bar puts them (2026-09-21 — before, every
    /// such reveal dropped the picture and ran cover-only).
    private var revealedStripShift: CGFloat {
        guard let (then, now) = revealedStripMove, abs(then - now) > 1 else { return 0 }
        return now - then
    }

    /// The strip as it looks now — revealed, at rest, no picture over it —
    /// becomes the finished picture. Callers check the reveal state.
    private func takeRevealedStripPicture(reason: String) async {
        guard let appState, !Task.isCancelled, !ConcealGhostOverlay.stripActive else { return }
        // The reveal cover's footprint, so the two pictures overlay
        // exactly (same rect, same padding).
        let signature = hiddenSectionSignature
        let chevronX = liveChevronMinX
        let anchor = liveAnchor
        let activeDisplay = appState.lastMouseDownDisplay
        let backdrop = ConcealGhostOverlay.backdropSignature(of: revealCoverRect) + ConcealGhostOverlay.surfaceSignature()
        let underPanel = ClockClickRelay.notificationCenterIsOpen()
        // Under a held bar's picture the icons are still there (#88).
        let taken = await ConcealGhostOverlay.snapshotSet(of: revealCoverRect, excludingOwnWindows: !held.isEmpty)
        guard !Task.isCancelled else { return }
        revealedStripSignature = signature
        revealedStripChevronX = chevronX
        revealedStripAnchor = anchor
        revealedStripActiveDisplay = activeDisplay
        revealedStripBackdrop = backdrop
        revealedStripBackground = []
        revealedStripKeep = nil
        revealedStripUnderPanel = underPanel
        revealedStripSnapshot = taken
        PelmetLog.log("finished: picture taken at \(reason) (\(revealedStripSnapshot.count) display(s), \(revealedStripSignature.count) hidden item(s))")
    }


    private func scheduleRevealedStripPrecapture() {
        revealedPrecaptureTask?.cancel()
        revealedPrecaptureTask = Task { @MainActor in
            guard let appState else { return }
            await appState.waitUntilQuiesced(interval: 0.5, deadline: 3, poll: .milliseconds(50))
            // The reveal's cover lifts at `entranceCoverHold` past settle:
            // wait for it rather than skip the picture (a skipped picture
            // costs the next conceal a live capture, #35). Only a Fade
            // lift has a tail that could bake in.
            let lifted = Date().addingTimeInterval(2)
            while ConcealGhostOverlay.stripActive, Date() < lifted, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
            }
            if appState.settings.revealAnimation == .fade {
                try? await Task.sleep(for: AppTiming.precaptureGhostClearance)
            }
            guard !Task.isCancelled, appState.currentRevealedSections == [.hidden] else { return }
            // An icon Show in Menu Bar has out on top of the section would
            // be in the picture, and the next reveal would flash it. One a
            // show rule has out is on the bar for every reveal while the
            // rule holds, and a rule change drops the picture
            // (showRuleChanged): it may be in it (review B5).
            guard appState.itemsInBar.isEmpty else {
                PelmetLog.log("finished: an icon is out on the bar, no picture at settle")
                return
            }
            await takeRevealedStripPicture(reason: "settle")
        }
    }

    /// Once the bar has gone swap-quiet after a conceal, the strip region
    /// shows exactly the "empty bar" the next reveal wants to freeze — and
    /// the next conceal's cover/cut-out reference for every style — capture
    /// it now. One in flight at a time: rapid conceal cycles otherwise stack
    /// overlapping 3s polls, each ending in an SCK capture.
    /// `afterConceal` false: a retake of a bar long at rest (#49) — no fade
    /// to clear, and the pointer is already on its way.
    private func scheduleRevealCoverPrecapture(afterConceal: Bool = true) {
        precaptureTask?.cancel()
        precaptureGeneration &+= 1
        let generation = precaptureGeneration
        precaptureInFlight = true
        precaptureTask = Task { @MainActor in
            // A replaced capture leaves the flag to its replacement.
            defer { if generation == precaptureGeneration { precaptureInFlight = false } }
            guard let appState, !Task.isCancelled else { return }
            await appState.waitUntilQuiesced(interval: 0.5, deadline: 3, poll: .milliseconds(afterConceal ? 200 : 30))
            // The agent's own conceal fade must not bake into the snapshot.
            if afterConceal { try? await Task.sleep(for: AppTiming.precaptureGhostClearance) }
            // Nor a lift's re-hide cover, up until the bar beneath has settled.
            let liftWait = Date().addingTimeInterval(AppTiming.liftCoverSafety)
            while liftEnding, !Task.isCancelled, Date() < liftWait { try? await Task.sleep(for: .milliseconds(50)) }
            guard !Task.isCancelled, appState.currentRevealedSections.isEmpty else { return }
            guard !pressHoldsBar else {
                PelmetLog.log("cover: item press holds the bar, precapture skipped")
                return
            }
            // Under Notification Center's panel the bar is not the bar a
            // reveal or a clock click will find: leave the bare picture
            // (or its absence) alone, the blink keeps its own picture of
            // the bar under the panel (#51).
            guard !ClockClickRelay.notificationCenterIsOpen() else {
                PelmetLog.log("cover: panel open, precapture skipped")
                return
            }
            let activeDisplay = appState.lastMouseDownDisplay ?? Self.displayUnderPointer
            let rect = precaptureRect
            let backdrop = ConcealGhostOverlay.backdropSignature(of: rect) + ConcealGhostOverlay.surfaceSignature()
            let underPanel = ClockClickRelay.notificationCenterIsOpen()
            let ownBar = appState.ownBarSignature
            let epoch = pressEpoch
            let taken = await ConcealGhostOverlay.snapshotSet(of: rect)
            guard !Task.isCancelled else { return }
            guard epoch == pressEpoch, !pressHoldsBar else {
                PelmetLog.log("cover: idle picture dropped, an item press had the bar while it was taken")
                revealCoverSnapshot = []
                revealCoverTakenRect = nil
                revealCoverWanted = true
                return
            }
            revealCoverSnapshot = taken
            revealCoverActiveDisplay = activeDisplay
            revealCoverBackdrop = backdrop
            revealCoverTakenRect = rect
            revealCoverOwnBar = ownBar
            revealCoverUnderPanel = underPanel
            revealCoverWanted = false
            parkedCover = nil
        }
    }

    /// Boot: the first conceal is the engine's own converge, not a
    /// `performConceal`, so nothing measured the strip and the first reveal
    /// of every launch ran without pictures (macOS's own slide showed).
    /// The launch snapshot was taken before any assertion — every hidden
    /// item still had a frame — so the strip is known from it; the empty-
    /// bar picture follows once the boot conceal has settled.
    func warmAfterBoot(from snap: EngineSnapshot) {
        guard seedStripAtBoot(from: snap) else { return }
        scheduleRevealCoverPrecapture()
    }

    /// Idempotent: the first call seeds, later ones return whether a strip
    /// is known.
    @discardableResult
    private func seedStripAtBoot(from snap: EngineSnapshot) -> Bool {
        guard lastConcealedStripRect == nil else { return true }
        guard let appState else { return false }
        var union: CGRect?
        var count = 0
        let primaryMaxX = primaryMaxX
        for item in snap.items {
            guard let frame = item.frame, MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX),
                  appState.settings.sectionModel.section(of: item.id) != .visible
            else { continue }
            count += 1
            union = union.map { $0.union(frame) } ?? frame
        }
        concealableCount = count
        guard let union else { return false }
        rememberStrip(union)
        PelmetLog.log("strip: seeded at boot from \(count) pre-assertion frame(s) → \(Int(union.minX))..\(Int(union.maxX))")
        return true
    }

    /// Boot, before the first converge: the bar is fully live, and the
    /// hidden section sits exactly where the first reveal will bring it
    /// back. A picture of it now, with the hidden run cut out against the
    /// empty bar the boot conceal leaves, makes the first reveal of the
    /// session as instant as the ones after it — it used to pay the
    /// cover-only path every launch (Gab, 2026-09-18). The always-hidden
    /// icons are live too, so only the hidden run is kept; an always-hidden
    /// icon sitting inside that run (untidy bar) would ride along, so the
    /// picture is skipped then.
    func takeBootPicture(from snap: EngineSnapshot) async {
        guard let appState, seedStripAtBoot(from: snap), let rect = revealCoverRect else { return }
        let model = appState.settings.sectionModel
        let primaryMaxX = primaryMaxX
        var hidden: CGRect?
        var alwaysHidden: [CGRect] = []
        for item in snap.items {
            guard let frame = item.frame, MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX) else { continue }
            switch model.section(of: item.id) {
            case .hidden: hidden = hidden.map { $0.union(frame) } ?? frame
            case .alwaysHidden: alwaysHidden.append(frame)
            default: break
            }
        }
        guard let hidden else { return }
        guard !alwaysHidden.contains(where: { $0.midX > hidden.minX && $0.midX < hidden.maxX }) else {
            PelmetLog.log("finished: boot picture skipped — an always-hidden icon sits inside the hidden run")
            return
        }
        revealedStripSignature = hiddenSectionSignature
        revealedStripChevronX = liveChevronMinX
        revealedStripAnchor = liveAnchor
        revealedStripActiveDisplay = appState.lastMouseDownDisplay ?? Self.displayUnderPointer
        revealedStripBackdrop = ConcealGhostOverlay.backdropSignature(of: rect) + ConcealGhostOverlay.surfaceSignature()
        revealedStripBackground = []
        revealedStripKeep = (hidden.minX - 6)...(hidden.maxX + 6)
        revealedStripUnderPanel = ClockClickRelay.notificationCenterIsOpen()
        revealedStripSnapshot = await ConcealGhostOverlay.snapshotSet(of: rect)
        PelmetLog.log("finished: boot picture taken (\(revealedStripSnapshot.count) display(s), \(revealedStripSignature.count) hidden item(s), keep \(Int(hidden.minX))..\(Int(hidden.maxX)))")
    }

    /// Union of the on-screen frames about to conceal (primary band
    /// only): everything assigned to a non-visible section that currently has
    /// a frame. Nil when nothing concealable is showing. Re-snapshots: AX
    /// lists freshly revealed items progressively, and the settle-time
    /// snapshot can be missing half the strip.
    private func concealStripFrames() async -> CGRect? {
        guard let appState else { return nil }
        // The rest walk behind the reveal swap listed the whole strip;
        // walking again here cost 70–130ms before every conceal swap.
        let snap: EngineSnapshot
        if let rest = await engine.restSnapshot { snap = rest } else { snap = await engine.snapshot() }
        var union: CGRect?
        var count = 0
        concealableCount = snap.items.filter {
            !$0.id.isSystemModule && appState.settings.sectionModel.section(of: $0.id) != .visible
        }.count
        let primaryMaxX = primaryMaxX
        for item in snap.items {
            guard let frame = item.frame,
                  MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX),
                  appState.settings.sectionModel.section(of: item.id) != .visible
            else { continue }
            count += 1
            union = union.map { $0.union(frame) } ?? frame
        }
        PelmetLog.log("strip: \(count) items → \(union.map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "nil")")
        return union
    }
}

// MARK: - Picture pass (docs/PANEL-PLAN.md §8 S1, decision D2)

extension TransitionCoordinator {
    /// With the bar at rest: `sections` revealed under a cover, each item
    /// cut out against the empty bar with Pelmet's windows left out,
    /// concealed, cover lifted. A 60fps film of S1 showed no motion on the
    /// bar; the capture dot shows for about a second. Pictures by section
    /// key; nil when the pass never saw the icons (the bar revealed, no
    /// Screen Recording, none drawn), so nothing counts as unpicturable.
    /// `failed`: the `wanting` keys the pass tried and got no picture of,
    /// empty without an empty-bar picture to cut against; a key whose round
    /// was skipped (a waiter, another press's icon) is not one.
    /// `dump` writes them to ~/Library/Logs/Dimble/pass/.
    ///
    /// A section wider than the room right of the notch draws only some of
    /// its icons; the rest get no frame or a phantom one. Of the `wanting`
    /// items the first round saw that way on the primary bar, up to
    /// `PicturePassBatches.maxFollowUps` more rounds reveal just those,
    /// under the same cover, and stop as soon as one pictures nothing new,
    /// or a reveal or a press wants the bar. The first round is the same
    /// with or without them, and with none to follow up nothing extra runs.
    func picturePass(
        _ sections: Set<PelmetCore.Section>, wanting: Set<ItemID> = [], dump: Bool = false,
        seen: ((_ absent: Set<ItemID>) -> Void)? = nil
    ) async -> (pictures: [ItemID: ItemPictures.Picture], failed: Set<ItemID>, absent: Set<ItemID>)? {
        guard let appState else { return nil }
        let dump = dump || UserDefaults.standard.bool(forKey: "pelmet.debug.dumpPass")
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        // Anchored (#88), Hidden is out for good and the bar rests that way:
        // the pass films it as it is and ends back at the anchor.
        let anchoredPass = anchored
        guard barRestsForPass else {
            PelmetLog.log("pass: bar is revealed, skipped")
            return nil
        }
        // An icon Show in Menu Bar has out is on the "empty" bar the pass
        // films its crops against.
        guard appState.itemsInBar.isEmpty else {
            PelmetLog.log("pass: an icon is out on the bar, skipped")
            return nil
        }
        guard !passInFlight else {
            PelmetLog.log("pass: one is running, skipped")
            return nil
        }
        // An icon a press revealed alone, or the « it expanded: the reveal
        // would reflow the bar under the menu it opened (review XF-3). The
        // next open takes the pictures.
        guard !pressHoldsBar else {
            PelmetLog.log("pass: an item press holds the bar, deferred")
            return nil
        }
        guard appState.screenRecordingGranted else {
            PelmetLog.log("pass: no Screen Recording, skipped")
            return nil
        }
        beginBarHold(.picturePass)
        // By section, not the walk's `concealed`: that misses system items
        // such as Sound, which leave the AX tree when hidden.
        let model = appState.settings.sectionModel
        // Battery or Wi-Fi a show rule has out (#86) is on the empty bar
        // too, where it sits concealed: not a target, and a crop filmed
        // over that spot would be cut against it. Both wait out `maxAge`
        // like any icon that won't picture; the rest picture as ever
        // (review B5, the pass used to skip while a rule had one out).
        let ruleOut = ruleShownOut
        let ruleFrames = (appState.snapshot?.items ?? []).compactMap { ruleOut.contains($0.id.sectionKey) ? $0.frame : nil }
        func clearOfRule(_ frame: CGRect) -> Bool {
            !ruleFrames.contains { min($0.maxX, frame.maxX) - max($0.minX, frame.minX) > 2 }
        }
        // Anchored with no cover to go under, Always Hidden stays in.
        var passSections = sections
        func wanted(_ id: ItemID) -> Bool {
            passSections.contains(model.section(of: id.sectionKey)) && !ruleOut.contains(id.sectionKey)
        }
        // Anchored, the idle picture isn't kept and the icons are out: the
        // bare bar (WindowServer's bar window left out) is the empty one.
        var empty = anchoredPass ? [] : freshEmptyBarSnapshots(cropped: false)
        let emptySource = anchoredPass ? "captured bare" : empty.isEmpty ? "captured" : "precaptured"
        if empty.isEmpty {
            empty = await ConcealGhostOverlay.snapshotSet(
                of: precaptureRect, excludingOwnWindows: true, primaryOnly: true, bare: anchoredPass)
        }
        PelmetLog.log("pass: empty bar \(emptySource) at \(ms())ms (\(empty.count) display(s))")

        // A walk that shows the icons `watch` names and agrees with the one
        // before it: read while they still slid in, S1's crops were off by
        // up to an icon, and two walks from before they came agree too.
        func settledWalk(
            watching watch: (ItemID) -> Bool, awaiting: Set<ItemID> = [], quiet: TimeInterval = 0.2,
            leaving: ((EngineSnapshot) -> Bool)? = nil, label: String? = nil
        ) async -> EngineSnapshot {
            await appState.waitUntilQuiesced(interval: quiet, deadline: 2, poll: .milliseconds(30))
            // What was just put away leaves the agent's tree a moment later
            // (system items such as Sound after the rest), and its frame
            // overlaps the ones that took its place: a read with it still
            // there takes those for phantoms, and films its pixels.
            if let leaving {
                let by = Date().addingTimeInterval(AppTiming.picturePassLeave)
                var last = await engine.freshSnapshot()
                while Date() < by, leaving(last) {
                    try? await Task.sleep(for: .milliseconds(60))
                    last = await engine.freshSnapshot()
                }
                if let label {
                    let there = leaving(last) ? " (gave up, still there: \(last.items.filter { $0.frame != nil && !watch($0.id) && wanted($0.id) }.map { "\($0.id.rawValue) \($0.frame.map { "\(Int($0.minX))…\(Int($0.maxX))" } ?? "")" }))" : ""
                    PelmetLog.log("pass: \(label) put away, gone at \(ms())ms\(there)")
                }
            }
            var snap = await engine.snapshot()
            for k in 0..<12 {
                try? await Task.sleep(for: .milliseconds(50))
                let next = await engine.snapshot()
                // The icons the panel asked for are in the walk too: settled on
                // the first one in, the walk framed Shortcuts before Snib came
                // and pushed it aside, and its cut was half of Snib (2026-10-12).
                let listed = Set(next.items.map(\.id.sectionKey))
                let arrived = next.items.contains { watch($0.id) && $0.frame != nil } && awaiting.isSubset(of: listed)
                let settled = arrived && next.items.map(\.frame) == snap.items.map(\.frame)
                if let label, settled || k == 11 {
                    let mine = next.items.filter { watch($0.id) }.map { $0.frame.map { "\(Int($0.minX))…\(Int($0.maxX))" } ?? "none" }
                    PelmetLog.log("pass: \(label) read at \(ms())ms after \(k + 1) walk(s) \(mine)\(settled ? "" : ", still moving")")
                }
                snap = next
                if settled { break }
            }
            return snap
        }
        let primaryMaxX = primaryMaxX

        var coverStart = Date()
        // Anchored, only a section the anchor doesn't have out (Always
        // Hidden) changes the bar, under a cover of the bar as it looks:
        // held pictures included, so every display stays as it was.
        var adds = anchoredPass ? sections.subtracting(anchoredSections) : sections
        var cover = !anchoredPass || !adds.isEmpty ? await beginBarCover(label: "pass") : nil
        if anchoredPass, cover == nil, !adds.isEmpty {
            // Out bare, Always Hidden would show on the displays that show
            // all icons, and past a held picture's run.
            PelmetLog.log("pass: no cover, anchored — Always Hidden stays in")
            adds = []
            passSections = anchoredSections
        }
        let movesBar = !anchoredPass || !adds.isEmpty
        PelmetLog.log("pass: cover \(cover == nil ? "none" : "up")\(anchoredPass ? " (anchored, adds \(adds.count) section(s))" : "") at \(ms())ms")
        appState.picturePassSections = anchoredPass ? passSections.union(anchoredSections) : sections
        if movesBar { await engine.reveal(anchoredPass ? passSections.union(anchoredSections) : sections) }
        // An app that quit since the panel drew never comes: waiting on it
        // held every walk to the deadline.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let awaiting = Set(wanting.filter { wanted($0) && $0.bundleID.map(running.contains) != false })
        let snap = await settledWalk(watching: { wanted($0) }, awaiting: awaiting)
        appState.updateSnapshot(snap)
        // The panel orders its tiles the way the bar just drew them.
        appState.recordDrawnOrder(snap, revealed: anchoredPass ? passSections.union(anchoredSections) : sections)
        let drawn = snap.items.filter { wanted($0.id) && $0.frame != nil }
        let onPrimary = drawn.filter { MenuBarGeometry.isInPrimaryBand($0.frame!, primaryMaxX: primaryMaxX) }
        PelmetLog.log("pass: revealed at \(ms())ms (\(drawn.count) drawn, \(onPrimary.count) on the primary bar)")
        // Waited for and never listed, with the others drawn around it: its
        // app runs with no icon in the bar (CleanShot with its own icon
        // switched off kept a tile, #26). One behind the « is still listed.
        let listedKeys = Set(snap.items.map(\.id.sectionKey))
        let absent = drawn.isEmpty ? [] : Set(awaiting.filter { !listedKeys.contains($0.sectionKey) })
        if !absent.isEmpty { PelmetLog.log("pass: no icon on the bar for \(absent.map(\.rawValue).sorted())") }
        if !drawn.isEmpty { seen?(absent) }

        var pictures: [ItemID: ItemPictures.Picture]? = drawn.isEmpty ? nil : [:]
        // Only what the bar draws clear: an icon the native « holds reports
        // a frame stacked on the others behind it, and a cut of it is the «
        // (#81, every tile a chevron on a full MacBook Air bar). The rounds
        // below give those the room to themselves.
        let primaryFrames = snap.items.compactMap { item in
            item.frame.flatMap { MenuBarGeometry.isInPrimaryBand($0, primaryMaxX: primaryMaxX) ? (key: item.id.sectionKey, frame: $0) : nil }
        }
        let first = PicturePassBatches.drawn(wanted: Set(onPrimary.map(\.id.sectionKey)), frames: primaryFrames)
        if !first.phantoms.isEmpty {
            PelmetLog.log("pass: \(first.phantoms.count) behind the «, not cropped")
        }
        let solid = primaryFrames.filter { first.solid[$0.key] == $0.frame }
        let shown = solid.filter { clearOfRule($0.frame) }
        if shown.count < solid.count {
            PelmetLog.log("pass: \(solid.count - shown.count) where a show rule's icon sits on the empty bar, not cropped")
        }
        var movedWhileFilmed = Set<ItemID>()
        if !shown.isEmpty {
            let film = await filmAndCut(shown, empty: empty, dump: dump, ms: ms)
            for (key, picture) in film.pictures {
                pictures?[key] = picture
            }
            movedWhileFilmed = film.moved
            PelmetLog.log("pass: \(pictures?.count ?? 0) of \(onPrimary.count) pictures at \(ms())ms")
        }

        // The narrow fallback: what the walk saw frameless or behind the «
        // on the primary bar gets the room to itself, a round at a time.
        // Everything else (every wanted item clear, a blank cut, a side
        // display) is as it always was, and nothing below runs.
        var leftovers = Set<ItemID>()
        // Left over and never given a round: not tried, not failed.
        var deferred = Set<ItemID>()
        var roundsRan = false
        if pictures != nil, !wanting.isEmpty {
            let asking = Set(wanting.filter(wanted))
            leftovers = PicturePassBatches.leftovers(
                wanted: asking, items: snap.items.map { (key: $0.id.sectionKey, frame: $0.frame) }, primaryMaxX: primaryMaxX)
            // An icon that moved under the film gets a round too: the «
            // kicked in mid-film on a full reveal, all 15 moved and none was
            // cut (2026-10-12 23:09). Out on their own, the bar is quiet.
            leftovers.formUnion(movedWhileFilmed.intersection(asking))
        }
        if !leftovers.isEmpty {
            // Another press's ids stay out of the rounds: putting them back
            // would pull an icon from under the menu it opened.
            let theirs = await engine.itemsRevealedOnTheirOwn()
            deferred = leftovers
            leftovers.subtract(theirs)
            deferred.subtract(leftovers)
            // Anchored, a Hidden-only pass went without a cover: the rounds
            // reflow the bar, so they get one now, of the bar as it looks.
            if anchoredPass, cover == nil, !leftovers.isEmpty {
                coverStart = Date()
                cover = await beginBarCover(label: "pass")
                PelmetLog.log("pass: cover \(cover == nil ? "none" : "up") for the rounds (anchored) at \(ms())ms")
            }
            var roundsAsked = Set<ItemID>()
            let ceiling = AppTiming.transitionCoverSafety + Double(PicturePassBatches.maxFollowUps) * AppTiming.picturePassBatch
            var sectionsOut = true
            var itemsOut = Set<ItemID>()
            var followUps = 0
            var lastPictured = 0
            while PicturePassBatches.wantsAnotherRound(followUpsDone: followUps, leftovers: leftovers, lastRoundPictured: lastPictured) {
                let elapsed = -coverStart.timeIntervalSinceNow
                if let blocker = PicturePassBatches.blocker(
                    .init(hasCover: cover != nil, hasEmptyBarPicture: !empty.isEmpty,
                          otherPressHoldsBar: otherPressHoldsBar, waiterPending: passHasWaiter),
                    elapsed: elapsed, batch: AppTiming.picturePassBatch, ceiling: ceiling
                ) {
                    PelmetLog.log("pass: batch skipped — \(blocker.reason) (batch \(followUps + 1), \(leftovers.count) left)")
                    deferred.formUnion(leftovers.subtracting(roundsAsked))
                    break
                }
                followUps += 1
                roundsRan = true
                // The cover is held up for this round only, once it starts.
                cover?.keepUp(for: AppTiming.picturePassBatch + PicturePassBatches.liftReserve)
                // One swap a round: the items come out before the sections go
                // back, and later rounds only put away what got its picture.
                let asked = leftovers
                roundsAsked.formUnion(asked)
                let out = asked.subtracting(itemsOut)
                if !out.isEmpty { await engine.reveal(items: out) }
                if sectionsOut {
                    // The engine is about to say "concealed": Pelmet's own
                    // items follow it, or they would flip under the capture.
                    appState.picturePassSections = []
                    await engine.conceal()
                    sectionsOut = false
                }
                let back = itemsOut.subtracting(asked)
                if !back.isEmpty { await engine.conceal(items: back) }
                itemsOut = asked
                let walk = await settledWalk(
                    watching: { asked.contains($0.sectionKey) },
                    leaving: { snap in snap.items.contains { wanted($0.id) && !asked.contains($0.id.sectionKey) && $0.frame != nil } },
                    label: "batch \(followUps)")
                let bar = walk.items.compactMap { item in
                    item.frame.flatMap { MenuBarGeometry.isInPrimaryBand($0, primaryMaxX: primaryMaxX) ? (key: item.id.sectionKey, frame: $0) : nil }
                }
                let now = PicturePassBatches.drawn(wanted: asked, frames: bar)
                if !now.phantoms.isEmpty {
                    PelmetLog.log("pass: batch \(followUps) has \(now.phantoms.count) behind the «, not cropped")
                }
                let cut = bar.filter { now.solid[$0.key] == $0.frame && clearOfRule($0.frame) }
                let got = cut.isEmpty ? [:] : await filmAndCut(cut, empty: empty, dump: false, ms: ms).pictures
                for (key, picture) in got { pictures?[key] = picture }
                lastPictured = got.count
                leftovers = PicturePassBatches.remaining(asked, pictured: Set(got.keys))
                PelmetLog.log("pass: batch \(followUps) revealed \(asked.count), pictured \(got.count), left \(leftovers.count) at \(ms())ms")
            }
            if !itemsOut.isEmpty { await engine.conceal(items: itemsOut) }
        }

        appState.picturePassSections = nil
        if !anchoredPass {
            await engine.conceal()
        } else if roundsRan {
            // Back to the anchor, not concealed: the displays that show all
            // icons keep them. The rounds put every section away.
            await engine.reveal(anchoredSections)
        } else if movesBar {
            // Always Hidden goes back, Hidden stays out.
            await engine.narrowReveal(to: anchoredSections)
        }
        appState.updateSnapshot(await engine.snapshot())
        PelmetLog.log("pass: \(anchoredPass ? "back to the anchor" : "concealed") at \(ms())ms")
        if anchoredPass, let cover {
            // The held pictures fit the bar as it settles, before the pass
            // cover lifts off it: frames read right after the reveal sit
            // right of where it rests.
            cover.keepUp(for: AppTiming.transitionCoverSafety)
            await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
            appState.updateSnapshot(await engine.snapshot())
            await hold(appState.barsKeptConcealed)
            PelmetLog.log("pass: held bars back at \(ms())ms")
        }
        if let cover {
            endBarCover(cover, label: "pass") { [weak self] in
                self?.endBarHold()
                PelmetLog.log("pass: cover lifted at \(ms())ms")
            }
        } else {
            endBarHold()
        }
        guard let pictures else { return nil }
        // Against no empty bar nothing could be cut: says nothing either
        // (review WRAP-1, every tile stood in for 15 minutes).
        let failed: Set<ItemID> = empty.isEmpty ? [] : wanting.subtracting(pictures.keys).subtracting(deferred)
            .filter { passSections.contains(model.section(of: $0.sectionKey)) }
        return (pictures, failed, absent)
    }

    /// An Apply a panel drop started, with the panel left open: the bar goes
    /// out under a cover like a picture pass's, the pass runs (`body`: the
    /// drags and their verifying), the bar is concealed again, and only then
    /// does the cover lift, on the bar as it rests. Nothing of the pass shows,
    /// and the rehide machine never hears of it: it still says the panel is
    /// revealed, so nothing closes the panel for the bar's reveal.
    ///
    /// Nil, with `body` not run, when the bar is not free or no cover could be
    /// raised: the caller then runs the pass as an Apply always has. A
    /// reveal, a press or a picture pass that arrives meanwhile waits for the
    /// cover to be off (`passInFlight`), as it does for a picture pass.
    /// `lifted` runs once the cover is off.
    func holdBarForApply<T>(
        revealing sections: Set<PelmetCore.Section>,
        run body: () async -> T,
        lifted: @escaping @MainActor () -> Void
    ) async -> T? {
        guard let appState else { return nil }
        // A picture pass has the bar (the panel's first open): wait it out.
        await awaitPicturePass()
        // Anchored, the drags would land on a held picture: the Apply runs
        // as a plain one, which lifts them (#88).
        guard !passInFlight, appState.currentRevealedSections.isEmpty else {
            PelmetLog.log("apply: quiet pass skipped, \(anchored ? "the bar is anchored" : "the bar is busy")")
            return nil
        }
        beginBarHold(.quietApply)
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        // The ghost of the tile just dropped is still fading over the bar.
        try? await Task.sleep(for: AppTiming.quietApplyGhostFade)
        guard let cover = await beginBarCover(label: "apply", safety: AppTiming.quietApplyCoverCeiling) else {
            PelmetLog.log("apply: quiet pass skipped, no cover")
            endBarHold()
            return nil
        }
        PelmetLog.log("apply: quiet (panel drop), cover held at \(ms())ms")
        // Pelmet's own items follow the bar, as in a picture pass.
        appState.picturePassSections = sections
        await engine.reveal(sections)
        try? await Task.sleep(for: AppTiming.tidyRevealWait)
        let result = await body()
        // The order the bar has now is the one the panel draws next.
        // Only the order: read as the app's snapshot, the whole bar out at
        // once put a full bar's worth behind the « in "Didn't fit" (2026-10-12).
        let drawn = await engine.snapshot()
        appState.recordDrawnOrder(drawn, revealed: sections)
        appState.picturePassSections = nil
        await engine.conceal()
        PelmetLog.log("apply: quiet pass concealed at \(ms())ms")
        // The lift below waits for the bar to settle, which can outlast what
        // is left of the ceiling after a long pass.
        cover.keepUp(for: AppTiming.clockBlinkCoverDeadline + 2)
        endBarCover(cover, label: "apply") { [weak self] in
            guard let self else { return }
            self.endBarHold()
            PelmetLog.log("apply: quiet cover lifted at \(ms())ms")
            // The bar as it is now, the put-away icons gone from the walk.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState?.updateSnapshot(await self.engine.freshSnapshot())
                lifted()
            }
        }
        return result
    }

    /// A strip filmed over `items` as the bar draws them, each one cut out
    /// of it against `empty`. Nothing for an empty list.
    private func filmAndCut(
        _ items: [(key: ItemID, frame: CGRect)],
        empty: [ConcealGhostOverlay.BarSnapshot], dump: Bool, ms: () -> Int
    ) async -> (pictures: [ItemID: ItemPictures.Picture], moved: Set<ItemID>) {
        let frames = items.map(\.frame)
        guard let minX = frames.map(\.minX).min(), let maxX = frames.map(\.maxX).max(), let band = frames.first else { return ([:], []) }
        let rect = CGRect(x: minX - 8, y: band.minY, width: maxX - minX + 16, height: band.height)
        // AX reports where the icons land before the bar has drawn them
        // there: crops of a strip filmed mid-slide took halves of their
        // neighbours (Always Hidden, 2026-10-09). Film until two frames
        // agree. Pelmet's windows are looked up once for the film, each
        // frame decoded once.
        let own = await ConcealGhostOverlay.ownWindows()
        var strip = await ConcealGhostOverlay.snapshotSet(of: rect, excludingOwnWindows: true, ownWindows: own, primaryOnly: true)
        var decoded = strip.map(Self.decoded)
        var filmed = 1
        var lastApart: Double = 1
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(80))
            let next = await ConcealGhostOverlay.snapshotSet(of: rect, excludingOwnWindows: true, ownWindows: own, primaryOnly: true)
            let nextDecoded = next.map(Self.decoded)
            filmed += 1
            if dump { Self.dumpPass(next, name: "_strip\(filmed)") }
            let apart = next.count == strip.count ? zip(decoded, nextDecoded).map { Self.pixelsApart($0, $1) }.max() ?? 1 : 1
            strip = next
            decoded = nextDecoded
            lastApart = apart
            if apart < 0.005 { break }
        }
        PelmetLog.log("pass: strip captured at \(ms())ms (\(strip.count) display(s), \(filmed) frame(s), last \(String(format: "%.2f", lastApart * 100))% apart) x \(strip.map { "\(Int($0.windowFrame.minX))…\(Int($0.windowFrame.maxX))" }) items \(items.map { "\($0.key.rawValue) \(Int($0.frame.minX))…\(Int($0.frame.maxX))" })")
        // An icon that moved since the walk was filmed at its old place: a cut
        // there is its neighbour, stored under its key. It waits for the next
        // pass instead.
        let after = await engine.freshSnapshot()
        let still = items.filter { item in
            after.items.contains {
                $0.id.sectionKey == item.key && $0.frame.map { abs($0.minX - item.frame.minX) <= 1 && abs($0.maxX - item.frame.maxX) <= 1 } == true
            }
        }
        let moved = items.filter { item in !still.contains { $0.key == item.key && $0.frame == item.frame } }
        if !moved.isEmpty {
            PelmetLog.log("pass: \(moved.count) moved while filmed, not cut \(moved.map(\.key.rawValue))")
        }
        return (Self.pictures(of: still, strip: strip, empty: empty, dump: dump), Set(moved.map(\.key)))
    }

    /// A fresh picture of one item drawn on the bar right now: a relay's,
    /// once its menu is gone and before it is put away, under the relay's
    /// cover. Cut against the idle empty-bar picture; nil when there is
    /// none fresh, and the next pass retakes it then.
    func pictureItem(_ key: ItemID, frame: CGRect) async -> ItemPictures.Picture? {
        guard appState?.screenRecordingGranted == true else { return nil }
        guard MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX) else {
            PelmetLog.log("pass: \(key.rawValue) not on the primary bar, no picture")
            return nil
        }
        let rect = CGRect(x: frame.minX - 8, y: frame.minY, width: frame.width + 16, height: frame.height)
        // Anchored, no idle picture is kept: the bare bar there is the empty one.
        let empty = anchored
            ? await ConcealGhostOverlay.snapshotSet(of: rect, excludingOwnWindows: true, primaryOnly: true, bare: true)
            : freshEmptyBarSnapshots(cropped: false)
        guard !empty.isEmpty else {
            PelmetLog.log("pass: no fresh empty-bar picture for \(key.rawValue)")
            return nil
        }
        let strip = await ConcealGhostOverlay.snapshotSet(of: rect, excludingOwnWindows: true, primaryOnly: true)
        return Self.pictures(of: [(key, frame)], strip: strip, empty: empty, dump: false)[key]
    }

    /// One picture per item, cut from a strip filmed with the items drawn,
    /// against the empty bar. A plain strip carries the bar behind each
    /// icon: on glass that reads as a dark box, so a strip that won't cut
    /// out (an animated wallpaper) gives none, and the tiles keep their app
    /// icons.
    private static func pictures(
        of items: [(key: ItemID, frame: CGRect)],
        strip: [ConcealGhostOverlay.BarSnapshot], empty: [ConcealGhostOverlay.BarSnapshot], dump: Bool
    ) -> [ItemID: ItemPictures.Picture] {
        guard let cut = ConcealGhostOverlay.iconsOnly(strip, background: empty) else { return [:] }
        if dump {
            dumpPass(strip, name: "_strip")
            dumpPass(empty, name: "_empty")
        }
        let primary = NSScreen.screens.first?.frame
        guard let index = cut.firstIndex(where: { snap in primary.map { $0.minX <= snap.windowFrame.midX && snap.windowFrame.midX <= $0.maxX } ?? true })
        else { return [:] }
        let base = cut[index]
        // The strip as filmed and the empty bar under it: a one-colour glyph
        // is un-blended from the two.
        let raw = strip[index]
        let under = empty.first { abs($0.windowFrame.minY - raw.windowFrame.minY) < 1 && $0.windowFrame.intersects(raw.windowFrame) }
        let scale = CGFloat(base.image.width) / base.windowFrame.width
        var pictures: [ItemID: ItemPictures.Picture] = [:]
        for (key, f) in items {
            // Exactly the item's frame, less a point a side: neighbouring
            // frames overlap by a point or two, and `cropped(toPrimaryX:)`
            // pads, which let a neighbour's capsule (Velja's, Herd's) ride
            // along.
            guard f.minX >= base.windowFrame.minX, f.maxX <= base.windowFrame.maxX else { continue }
            let rect = CGRect(
                x: ((f.minX + 1 - base.windowFrame.minX) * scale).rounded(), y: 0,
                width: ((f.width - 2) * scale).rounded(), height: CGFloat(base.image.height))
            guard rect.width > 0, let image = base.image.cropping(to: rect) else { continue }
            let column = ConcealGhostOverlay.BarSnapshot(
                image: image,
                windowFrame: NSRect(x: f.minX + 1, y: base.windowFrame.minY, width: rect.width / scale, height: base.windowFrame.height),
                takenAt: base.takenAt)
            let bgRect = under.map { rect.offsetBy(dx: ((base.windowFrame.minX - $0.windowFrame.minX) * scale).rounded(), dy: 0) }
            guard let picture = ItemPictures.picture(
                from: column,
                raw: raw.image.cropping(to: rect),
                background: bgRect.flatMap { under?.image.cropping(to: $0) })
            else { continue }
            pictures[key] = picture
            if dump { dumpPass([column], name: key.rawValue) }
        }
        return pictures
    }

    /// Debug trigger (`pelmet.debug.picturePass`): Hidden (and Always
    /// Hidden), dumped to disk.
    func debugPicturePass(always: Bool = false) async {
        let sections: Set<PelmetCore.Section> = always ? [.hidden, .alwaysHidden] : [.hidden]
        // Every icon of those sections wanted, as a panel with none would
        // ask: the rounds run for the ones behind the «.
        // From the assignments: a concealed icon is not in the walk.
        let wanting = Set((appState?.settings.sectionModel.assignments ?? [:]).filter { sections.contains($0.value) }.keys)
        let found = await picturePass(sections, wanting: wanting, dump: true)
        PelmetLog.log("pass: debug — \(found.map { "\($0.pictures.count) picture(s)" } ?? "no pass")")
    }

    /// A filmed frame as `ItemPictures.rgba` reads it, kept for the next
    /// frame's comparison: decoded again there, every frame paid twice.
    private typealias DecodedFrame = (bitmap: ItemPictures.Bitmap?, width: Int, height: Int)

    private static func decoded(_ snap: ConcealGhostOverlay.BarSnapshot) -> DecodedFrame {
        (ItemPictures.rgba(snap.image, width: snap.image.width, height: snap.image.height), snap.image.width, snap.image.height)
    }

    /// The share of pixels two captures of the same strip disagree on; a
    /// playing Now Playing bar or a ticking clock keeps it above zero.
    private static func pixelsApart(_ a: DecodedFrame, _ b: DecodedFrame) -> Double {
        guard a.width == b.width, a.height == b.height, let pa = a.bitmap?.pixels, let pb = b.bitmap?.pixels else { return 1 }
        defer { withExtendedLifetime((a.bitmap?.context, b.bitmap?.context)) {} }
        let count = a.width * a.height
        var differing = 0
        for i in stride(from: 0, to: count * 4, by: 4) {
            if ItemPictures.distance(pa, pb, i) > 16 || abs(Int(pa[i + 3]) - Int(pb[i + 3])) > 16 {
                differing += 1
            }
        }
        return Double(differing) / Double(max(count, 1))
    }

    @discardableResult
    private static func dumpPass(_ snaps: [ConcealGhostOverlay.BarSnapshot], name: String) -> Bool {
        guard let image = snaps.first?.image else { return false }
        let dir = URL(fileURLWithPath: NSString(string: "~/Library/Logs/Dimble/pass").expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Re-rendered: a stream-backed image does not serialize.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        ctx.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return (try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(safe).png"))) != nil
    }
}
