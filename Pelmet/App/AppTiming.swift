// AppTiming.swift
// App-layer waits and windows tuned live against the agent's restart/reflow
// behavior. Values are load-bearing — rename freely, never retune casually.

import Foundation

enum AppTiming {
    /// Reveal/conceal cover watchdog.
    static let transitionCoverSafety: TimeInterval = 2.5
    /// Clock blink: replayed click's down→up hold, and how long after the
    /// up to re-acquire the assertion. The re-acquire delay doesn't change
    /// the visible flash (the agent finishes its reveal animation first —
    /// R=0/100/250ms all measured ~0.5s); it only keeps the click ahead.
    static let clockReplayHold: TimeInterval = 0.06
    static let clockBlinkReacquire: Duration = .milliseconds(120)
    /// Dot-zone clicks press the clock through AX after the drop: give the
    /// agent this long to apply the drop first, then this long for
    /// Notification Center's panel to show before pressing again.
    static let clockPressSettle: Duration = .milliseconds(120)
    /// A poll, not a sleep: it ends the moment the panel's window shows.
    /// 0.3 ran out on a four-display Mac where the list lags an opening by
    /// ~250ms, and the retry then closed the panel the first press had
    /// opened (#53); the extra budget only costs when the panel is late.
    static let clockPressVerify: TimeInterval = 0.6
    /// How long after the press the panel must still be up for the press to
    /// count, checked once per macOS build. On 27.2 beta 3 it asks for a
    /// close 78ms after the open and its window leaves the list ~450ms
    /// after the press, Pelmet or not (2026-10-07).
    static let clockPressHold: TimeInterval = 0.8
    /// Longest the blink cover waits for the concealed items to leave the
    /// AX tree after the re-acquire before lifting anyway.
    static let clockBlinkCoverDeadline: TimeInterval = 1.5
    /// Camera & mic relay (#68): longest Apple's pill may take to rejoin
    /// the AX tree after the drop before the relay gives up on it.
    static let audioVideoPillWait: TimeInterval = 1
    /// Live Activities lift (#106): a lift the re-hide ended sooner than this
    /// didn't give the pills time to say anything about them.
    static let liftPillWait: TimeInterval = 3
    /// Live Activities lift (#106): the re-hide cover's watchdog, past its
    /// longest settle (2s quiet + 1.5s for the concealed items + the
    /// agent's fade + 1s quiet again).
    static let liftCoverSafety: TimeInterval = 6
    /// A picture of the concealed bar taken at the lift's click reaches this
    /// far left of the idle one: the extras and the pills the lift lets
    /// back push the icons left (the capture stops at the notch).
    static let liftPictureLeftRoom: CGFloat = 200
    /// Notification Center's panel slides in over ~100ms from Pelmet's
    /// press; the blink cover crossfades from the bare still to the
    /// under-panel one over that slide, starting at the press.
    static let panelSlideIn: Duration = .milliseconds(0)
    static let panelSlideInFade: CFTimeInterval = 0.22
    /// Notification Center's leading edge, points in from the display's
    /// right edge, at each 1/60s of its entrance: filmed at 60fps with the
    /// blink uncovered, three runs averaged (Gab's built-in, 2026-09-22
    /// 17:17). The edge is where the bar's shade reaches half its depth.
    static let panelEntranceInsets: [CGFloat] = [0, 16, 40, 130, 215, 255, 288, 316, 336, 352, 364, 374, 380, 382]
    /// From the relay's click being up to the wipe's first frame. Filmed
    /// at ~35ms; tuned by eye against the panel's card below the bar,
    /// which trails the bar's own shade: 105ms with a kept under-panel
    /// still, 130ms with the click's own picture shaded (Gab, 2026-09-22
    /// 18:05).
    static let panelEntranceDelay: CFTimeInterval = 0.13
    /// Where the panel's leading edge comes to rest, in from the display's
    /// right edge, as the bar's shade shows it (1390pt on an 1800pt bar).
    static let panelShadeInset: CGFloat = 410
    /// The panel's leading edge as the glass shows it: a ~70pt ramp
    /// (60fps profile, 2026-09-22 14:28).
    static let panelEdgeSoftness: CGFloat = 110
    /// How long the blink cover stays after the concealed items have left
    /// the AX tree. Was `exitCoverHold` (0.42s) — the picture sat 1.0–1.5s
    /// on every clock click (#46). Measured 2026-09-21 at 60fps: lifting
    /// the moment they are gone shows no tail, the agent's fade is done by
    /// then. Kept as a knob at 0.
    static let clockBlinkLiftHold: TimeInterval = 0
    /// Adoption-window cover watchdog. The window itself runs up to
    /// `EngineTiming.adoptionWindowDeadline` (2.5s) and the converge that
    /// re-asserts follows it, so the blink's 2.5s would lift the picture
    /// mid-drop and show the very flash it is there to hide (#31).
    static let adoptionCoverSafety: TimeInterval = 6
    /// How long after a capture the bar is taken to be in its indicator-
    /// shifted place (see `ConcealGhostOverlay.captureIndicatorLit`): the
    /// indicator lasts ~3s, half a second is kept back for the edge.
    static let captureIndicatorHold: TimeInterval = 2.5
    /// Adoption deferral while a transition is in flight.
    static let adoptDeferralDelay: Duration = .milliseconds(300)
    static let adoptMaxDeferrals = 10
    /// Precaptured reveal-cover freshness: an appearance/wallpaper change
    /// while idle would flash a stale background.
    static let revealCoverFreshness: TimeInterval = 900
    /// How long a reveal waits for a cover retake still in flight (#49):
    /// a capture runs ~90ms here, up to ~470ms on a four-display Mac.
    static let coverRetakeWait: TimeInterval = 0.6
    /// How long a transition waits for the previous one's pictures to lift
    /// (#61): a lift lands 560–680ms after its click, measured 2026-09-24.
    static let previousLiftWait: TimeInterval = 0.8
    /// How long a reveal or a press waits for a picture pass to put the bar
    /// back: 11 icons took ~1.0s, measured 2026-10-09.
    static let picturePassWait: TimeInterval = 2.5
    /// What one follow-up batch of the picture pass is given (swaps, settle
    /// walks, strip): the cover is held up that long, plus the lift reserve,
    /// when one starts, and a waiting reveal or press waits that much longer
    /// at most. Measured 2026-10-10 with six icons and a menu bar too full
    /// for three: a batch took 1.1 to 1.5s, most of it the wait for what was
    /// put away to leave the AX tree.
    static let picturePassBatch: TimeInterval = 2.0
    /// Longest a follow-up waits for the items it just put away to leave the
    /// AX tree before reading the ones that took their place.
    static let picturePassLeave: TimeInterval = 1.0
    /// Backdrop check delay after an animated window move (tiling key,
    /// activation, Space switch): a Space switch animates ~0.5s. A mouse-up
    /// is checked at once — the window is already where the drag left it.
    static let backdropSettle: TimeInterval = 0.6
    /// A held picture's backdrop check waits this long after the last
    /// signal: a click's check ran before the clicked app raised its window,
    /// and the activation's check `backdropSettle` on retook every held bar
    /// again (77 of 427 retakes within 2s of the one before, log to
    /// 2026-10-25). Longer than `backdropSettle`, so that check lands inside
    /// the wait and restarts it: at 0.3s a Stage Manager switch still filmed
    /// twice, 0.63s apart (live, 3 displays, 2026-10-25).
    static let heldBackdropSettle: TimeInterval = backdropSettle + 0.1
    /// Style signatures (2026-09-08): the agent's own reveal slide is ~300ms
    /// and its conceal fade ~150–230ms; these sit clearly apart from both.
    /// Fade: the empty-bar cover's crossfade on reveal, the opaque strip's
    /// dissolve on hide. Smooth: the icons-only slide toward the chevron.
    static let fadeRevealDuration: CFTimeInterval = 0.26
    static let fadeExitDuration: CFTimeInterval = 0.34
    static let smoothExitDuration: CFTimeInterval = 0.24
    static let smoothRevealDuration: CFTimeInterval = 0.32
    /// Minimum time the reveal pictures stay up: the agent's slide-in is
    /// ~300ms and Pelmet's separators attach in the same reflow.
    static let entranceCoverHold: TimeInterval = 0.45
    /// Uncovered reveal: own items attach this long before the swap so the
    /// agent has laid them out by the time it runs the reveal (measured
    /// 2026-09-11: placed within a frame of the attach; the lead only needs
    /// to clear that).
    static let ownItemAttachLead: Duration = .milliseconds(50)
    /// How long the cover over a Show in Menu Bar conceal outlasts one of
    /// Pelmet's own extras: its ghost fades over 0.22s and the width
    /// collapses at 0.26s (StatusItemFader).
    static let ownItemFadeHold: Duration = .milliseconds(300)
    /// Minimum time the empty-bar cover stays over a conceal: the agent's
    /// own fade of the concealed items runs ~300ms past the swap.
    static let exitCoverHold: TimeInterval = 0.42
    /// How long another display's bar stays under its empty-bar picture
    /// while a bar reveal is out (#88) before it gives up and shows the
    /// icons: past this the picture risks a stale wallpaper or backdrop.
    /// Anchored (#88), a held picture is the bar for as long as a display
    /// that shows all icons is connected: refreshed, not timed out.
    static let anchoredBarCeiling: TimeInterval = 86_400
    static let heldBarCeiling: TimeInterval = 600
    /// Revealed-strip snapshot (taken at reveal settle) painted at once on the
    /// next Instant/Fade reveal. Long-lived: engine item changes invalidate it
    /// explicitly; the cap only guards wallpaper/appearance drift.
    static let revealedStripFreshness: TimeInterval = 900
    /// Apply waits for the full reveal to land before measuring.
    static let tidyRevealWait: Duration = .seconds(1.2)
    /// An own extra entering the bar is hosted before its one-item pass.
    static let newExtraPlacementDelay: Duration = .milliseconds(600)
    /// The second pass for an own item the first one found not laid out.
    static let ownItemRetryDelay: Duration = .milliseconds(1500)
    /// The boot own-item passes wait this long after the own items were
    /// adopted: 235ms after adoption the bar is still attaching (frames
    /// overlap, the chevron reads as trapped) and the pass planned on it —
    /// Media landed left of the chevron at 13:45 and was skipped as
    /// notOnScreen at 14:04, 2026-09-21. The post-swap and rest walks land
    /// within ~400ms of adoption.
    static let bootOwnItemLead: Duration = .seconds(2)
    /// Apply: a separator re-hosted onto a helper needs the helper up and
    /// its item registered before the bar is measured (launch → ready →
    /// hosts ≈ 100ms at boot; a cold launch takes longer).
    static let applyRehostWait: Duration = .milliseconds(1200)
    /// Below ~100ms every swipe-through of the band reads as a hover
    /// (the fire-time live-pointer check catches the rest).
    static let hoverDelayFloor: TimeInterval = 0.1
    /// Right-click claim (#140): not oftener than this while the pointer
    /// travels along the band. The verdict is a cross-process AX hit-test
    /// (~0.3ms) and a move already costs 0.24ms with the geometry cached.
    /// How long a taken claim then stands is the tap's own
    /// `BarRightClickTap.claimFreshness` — it is read off the main actor.
    static let barRightClickClaimRefresh: TimeInterval = 0.15
    /// A chevron click this soon after a hover reveal was dispatched was
    /// decided before the user could see the bar open (the picture is up
    /// ~100–200ms after dispatch, a reaction takes ~250ms more): it means
    /// "open", not "the opposite of where we're heading". Measured 2026-09-18:
    /// a click 95ms after the picture flashed open-shut-open, 350ms after
    /// it read as a close.
    static let hoverRevealClickGrace: TimeInterval = 0.5
    /// MenuBarAgent finalizes a ⌘-drag position before adoption reads it.
    static let dragAdoptDelay: TimeInterval = 0.35
    /// Rehide re-arm while deferred (pointer in band / elevated window).
    static let rehideDeferRearm: TimeInterval = 1.5
    /// Termination: max wait for engine.stop() before replying anyway.
    static let terminationStopDeadline: TimeInterval = 2
    /// Accessibility grant poll. A revoked grant only shows up as empty AX
    /// walks, so the app reads TCC directly; 2s keeps a flipped toggle in
    /// System Settings visible within a breath without a hot loop.
    static let accessibilityPoll: Duration = .seconds(2)
    /// Screen Recording grant poll, only while live mode waits on it
    /// (`ExtrasManager.syncLiveActivityWatcher`): same breath as above.
    static let screenRecordingPoll: Duration = .seconds(2)
    /// Apply (docs/CORE-SETS.md): the pass borrows the pointer only after
    /// this much quiet, bounded so a restless pointer still gets the
    /// shielded drag rather than a pass that never starts.
    static let applyIdleGap: TimeInterval = 1.5
    /// Drags in a row that miss, with the « on the bar, before a pass
    /// stops: each costs about 2s of the user's pointer (#81).
    static let applyOverflowMissLimit = 2
    static let applyIdleMaxWait: TimeInterval = 8
    /// The same wait in a quiet pass, which goes on shielded after it.
    static let quietApplyIdleMaxWait: TimeInterval = 0.5
    /// The cover a panel drop's Apply holds over the bar (docs/PANEL-PLAN.md):
    /// it stays up for the whole pass, not the 2.5s of a reveal. Passes took
    /// 0.9–2.8s, plus the idle wait above and the « round trip; it lifts on
    /// its own when the pass ends, and this is only the ceiling for a pass
    /// that hangs.
    static let quietApplyCoverCeiling: TimeInterval = 25
    /// The dropped tile's ghost fades for 0.12s over the bar: the cover's
    /// picture is taken after that.
    static let quietApplyGhostFade: Duration = .milliseconds(150)
    /// Keep sections grouped (docs/CORE-SETS.md, #80): the check waits this
    /// long after the last snapshot or roster change, so a reflow, a drop
    /// animation or a burst of registrations settles before anything is
    /// planned (and re-checks at this beat while a gate is closed).
    static let groupingDebounce: Duration = .seconds(2)
    /// …but never longer than this from the first unchecked change: a bar
    /// that keeps changing (hover reveals, covers, reflows every second or
    /// two) starved the pure debounce, and an editor drop was never looked at.
    static let groupingMaxWait: Duration = .seconds(6)
    /// An NSMenu fades for a beat after its tracking ends.
    static let groupingMenuHold: TimeInterval = 1
    /// The editor owns the order (M3): drift must read the same for this
    /// long before the keeper moves it, so an app relaunching or a bar
    /// still reflowing is not chased mid-flight.
    static let driftSettle: Duration = .seconds(10)
    /// …and passes are this far apart: an app that keeps re-placing its
    /// icon can't start a drag storm. Two tries per icon and stored order
    /// bound it too (M0 on Gab's bar, 2026-10-20: drift changed 5 times in
    /// 2 hours).
    static let driftCooldown: Duration = .seconds(120)
    /// How long the Apply button keeps its number over a raw count of 0
    /// while order edits are pending (`ApplyCountHold`). The dips measured
    /// 100–550ms before a walk read them back; a reveal's lasted 126ms
    /// (live test, 2026-10-13 21:13:26). A real 0 shows this much later.
    static let applyCountZeroHold: Duration = .milliseconds(300)
    /// How long the bar must stay full before the editor says so. Pelmet's
    /// own reflow after a drop or at Apply's start overflows for 0.4–1.3s
    /// (six times in one morning, 2026-10-07).
    static let overflowNoticeDelay: Duration = .seconds(2)
    /// Post-drag read: the agent animates the drop (~300ms slide, measured
    /// 2026-09-08) and a single fixed-delay read judged mid-flight frames as
    /// misses. Wait the floor, then re-read every poll until the dragged
    /// item's frame repeats `quiesceMatches` times, bounded by the cap.
    static let postDragSettleFloor: Duration = .milliseconds(150)
    static let postDragQuiescePoll: Duration = .milliseconds(45)
    static let postDragQuiesceMatches = 2
    static let postDragQuiesceCap: Duration = .milliseconds(900)
    /// Precapture waits this long after quiesce so the ghost's fade never
    /// bakes into the snapshot.
    static let precaptureGhostClearance: Duration = .milliseconds(300)
    /// Camera/mic indicator activation edge → one-item pass: the system
    /// camera pill often takes over within ~50ms and the indicator defers to
    /// it again — queuing before the flap settles queues a dead walk.
    static let cameraIndicatorPlaceDebounce: Duration = .milliseconds(500)
    /// Camera or mic goes live → the earliest Dimble's own replica may show,
    /// while `systemPillSurvivesAssertion` says Apple's pill is coming.
    /// macOS 27.3 builds that pill, destroys it and builds it again under a
    /// new UUID ~260ms later (measured 2026-11-07), so the AX read is false
    /// in the gap and the replica would show, leave and show again before
    /// live mode's mirror settles it. Past the longest settle seen (665ms),
    /// and short enough that a session Apple never marks still gets an
    /// indicator.
    static let cameraIndicatorPillGrace: Duration = .milliseconds(700)
    /// Relaunched app → adoption window: first wait lets the app construct
    /// its status item; the retry covers slow bootstraps (Electron vault
    /// apps build their tray ~20s in).
    static let relaunchAdoptionDelay: Duration = .seconds(3)
    static let relaunchAdoptionRetry: Duration = .seconds(15)
    /// Wake, unlock or a display change → is the chevron still on a bar
    /// (#26)? The walk is back ~200ms after an unlock, and the wait leaves
    /// the agent time to re-host what it will. A missing chevron gets one
    /// more look before it's re-hosted.
    static let chevronHostCheckDelay: Duration = .seconds(4)
    static let chevronHostConfirmDelay: Duration = .seconds(3)
    /// « expansion → re-measure: the trapped items reflow in left of the
    /// notch and the visible run shifts (~38pt) before frames are true.
    static let overflowExpandSettle: Duration = .milliseconds(700)

    /// Item press (ItemPress): how long a click gets to show a menu or
    /// panel before the item goes back, and how long an open one keeps the
    /// item revealed beneath the cover.
    static let pressMenuWait: TimeInterval = 3
    static let pressMenuCap: TimeInterval = 60
    /// When the only sign the press showed something is the app coming to
    /// the front, the item stays revealed at most this long.
    static let pressFrontCap: TimeInterval = 3
    /// A revealed item is clicked once its frame reads the same on two
    /// walks in a row (within this many points), the agent's slide-in over.
    /// Bounded: a frame that never settles is clicked where it last read.
    static let pressFrameTolerance: CGFloat = 1
    static let pressFrameCap: TimeInterval = 1
    /// A layer-0 window taller than this is a panel, not a bar row: the
    /// floor the press oracle counts a menu from (`ItemPress.counts`).
    nonisolated static let pressPanelFloor: CGFloat = 40
    /// What the oracle RECORDS a turned-down window from, below what it
    /// counts from. Measured 2026-11-14 (#151): a 30pt layer-0 panel was
    /// missed by the count and named by nothing, because the record shared
    /// the count's floor. Low enough that anything visible is named.
    nonisolated static let pressRecordFloor: CGFloat = 8
    /// A press waits this long for a reveal or conceal already running.
    static let pressTransitionWait: TimeInterval = 2
    /// A newer press makes the one before it yield: it still waits this
    /// long, at most, for its own menu to be gone (or to show) before the
    /// item goes back, so it is not concealed under a menu that is opening.
    static let pressYieldWait: TimeInterval = 0.8
    /// The cover hides the reveal and the click, then lifts so the real icon
    /// shows highlighted with its menu dropping from it. Not when the « was
    /// expanded for the press: the visible run sits ~38pt from where the
    /// cover's picture has it, and lifting would jump it. Flip to keep the
    /// cover up through the menu (the final conceal raises its own).
    static let pressCoverLiftsAfterClick = true

    /// The hidden-icons panel, from the mock: in with an 8pt drop as it
    /// fades, out rising 6pt. Reduce Motion keeps the fades alone.
    static let panelEntrance: TimeInterval = 0.18
    static let panelExit: TimeInterval = 0.14
    static let panelEntranceDrop: CGFloat = 8
    static let panelExitRise: CGFloat = 6

    /// Command bar panel: entrance (fade + a 4pt drop) and exit (fade). The
    /// exit is never longer than the entrance, so a Return never waits on it.
    static let searchEntrance: TimeInterval = 0.18
    static let searchExit: TimeInterval = 0.12
    /// A focus change this soon after the panel opened is the menu or the
    /// hotkey's own app handing focus over, not a click outside: the panel
    /// takes key back once.
    static let searchResignGuard: TimeInterval = 0.3
    /// The result count is announced to VoiceOver this long after the last
    /// keystroke, so typing doesn't queue one announcement per letter.
    static let searchAnnounceDelay: Duration = .milliseconds(450)
}
