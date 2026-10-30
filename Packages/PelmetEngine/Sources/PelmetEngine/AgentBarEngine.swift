// AgentBarEngine.swift
// The macOS 27 engine: converges the real menubar toward the desired
// SectionModel using assessment-mode assertions (hide), positions-plist writes
// (order), and AX (observe/click). One actor — every mutation is serialized,
// recovery is just another scheduled converge.

import AppKit
import Foundation
import PelmetCore

/// Phase timings of one converge, for the app's per-transition perf line.
/// Diagnostics only — nothing reads it to decide anything.
public struct ConvergeTiming: Sendable {
    public enum Outcome: String, Sendable {
        case swapped, noop, dropped, emptyWalk, unavailable, activationNil, superseded
    }
    /// The pre-swap AX walk (`refreshSnapshot`), ms — or the mirror reuse.
    public var walkMS = 0
    public var walkReused = false
    /// `ConvergePlan.compute` plus the running-apps fetch, ms.
    public var planMS = 0
    /// From the activate call to the completion (or the deadline), ms.
    public var activateMS = 0
    public var activated = false
    /// `previous.invalidate()` (the old assertion's XPC), ms.
    public var invalidateMS = 0
    public var outcome: Outcome = .superseded

    private var walkLabel: String { walkReused ? "mirror \(walkMS)ms" : "walk \(walkMS)ms" }

    public var summary: String {
        switch outcome {
        case .swapped:
            return "\(walkLabel) plan \(planMS)ms activate \(activateMS)ms\(activated ? "" : " (unconfirmed)") invalidate \(invalidateMS)ms"
        case .noop, .dropped:
            return "\(walkLabel) plan \(planMS)ms \(outcome.rawValue)"
        default:
            return "\(walkLabel) \(outcome.rawValue)"
        }
    }
}

public actor AgentBarEngine: MenuBarEngine {
    public nonisolated let capabilities = EngineCapabilities(
        canHide: AssessmentMode.isAvailable,
        hideGranularity: .bundleID,
        canReorder: true
    )

    public nonisolated var events: AsyncStream<EngineEvent> { eventStream }
    private nonisolated let eventStream: AsyncStream<EngineEvent>
    private nonisolated let eventContinuation: AsyncStream<EngineEvent>.Continuation

    private let enumerator = ItemEnumerator()

    /// Called on the main actor at the exact moment an assertion swap is
    /// issued (and on assertion drop), passing the revealed sections. App-side
    /// items that hide by their own width use this to change size in the SAME
    /// agent reflow — separate passes animate separately and read as sliding.
    public var reflowCompanion: (@MainActor @Sendable (Set<Section>) -> Void)?

    public func setReflowCompanion(_ companion: @MainActor @Sendable @escaping (Set<Section>) -> Void) {
        reflowCompanion = companion
    }

    /// An item-only reveal (and the release that ends it) changes no
    /// section: the extras have nothing to reflow, and applying them for
    /// "nothing revealed" ghost-hid an extra that its own rule re-showed a
    /// beat later (Siri blinking on every press, 2026-09-21). The mute only
    /// holds while the sections are the ones the companion last got: a hover
    /// that reveals one meanwhile is a real change and fires it.
    private var companionMuted = false
    private var companionSections: Set<Section>?

    private func notifyReflowCompanion() {
        guard let reflowCompanion else { return }
        let revealed = revealedSections
        if companionMuted, companionSections == revealed { return }
        companionSections = revealed
        Task { @MainActor in reflowCompanion(revealed) }
    }

    private var model = SectionModel()
    private var revealedSections: Set<Section> = []
    /// Items revealed on their own, sections untouched (a press brings one
    /// icon back beneath a cover). Owned by the press that revealed them:
    /// `conceal()` leaves them, so a rehide that lands mid-press cannot pull
    /// an item out from under the menu it opened. Released by
    /// `conceal(items:)`.
    private var revealedItems: Set<ItemID> = []
    /// Items a show rule keeps on the bar while its condition holds (#86:
    /// Battery while on battery). Apart from `revealedItems`, so a press
    /// releasing the same item never takes it off the bar.
    private var ruleShownItems: Set<ItemID> = []
    /// Both of the above whose section is not out: stamped on snapshots
    /// (`EngineSnapshot.shownAlone`).
    private var shownAlone: Set<ItemID> {
        revealedItems.union(ruleShownItems).filter {
            let section = model.section(of: $0)
            return section != .visible && !revealedSections.contains(section)
        }
    }
    /// Steady-assertion mode: hold an assertion even when nothing is
    /// concealable (allowlist = every observed bundle). Keeps macOS's
    /// collateral-hidden extras (Now Playing, camera pill, AirDrop, Focus)
    /// consistently gone, so the bar never reflows around them.
    private var steadyExtras = SettingsDefaults.hideSystemExtras
    /// A reveal that let the assertion go too (`reveal(_:liftingAssertion:)`,
    /// #106), until the conceal or narrow after it.
    private var lifted = false
    private var assertion: AssessmentAssertion?
    /// The allowlist/concealable pair the active assertion was built with.
    /// Converging to an equivalent state is a NO-OP — without this,
    /// converge→reflow→itemsChanged→converge oscillates forever.
    private var activeAllowlist: Set<String>?
    private var activeConcealable: Set<String>?
    private var activeSystemAllow: Set<Int>?

    /// MenuBarPolicy.identityExemptBundles bound to the running app's bundle
    /// id, computed once.
    public static let identityExemptBundles: Set<String> =
        MenuBarPolicy.identityExemptBundles(
            pelmetBundleID: PelmetBundle.mainID
        )

    /// A mirror not read at rest always gets a walk at rest behind it,
    /// whatever wrote it: a swap's stamp, a walk inside the reflow (behind a
    /// swap, a superseded converge's, a dropped assertion's), or a copy of
    /// one. The settle waits for that walk to judge a pending reorder, so a
    /// path that skipped it left Apply lit (review of N1, 2026-10-13).
    private var lastSnapshot: EngineSnapshot? {
        didSet { if lastSnapshot?.itemsAtRest == false { scheduleRestWalk() } }
    }
    private var restWalkScheduled = false
    /// `ConvergePlan.setAside` of the last converge that stamped its
    /// concealed set: concealed again by the next one that puts their
    /// section back. Stamped with the concealed set, never before the
    /// epoch guard: a converge a newer one superseded keeps the old set,
    /// or the ids it would have concealed again were lost from both
    /// (review B5).
    private var setAsideConcealed: Set<ItemID> = []
    private var started = false
    /// Actor reentrancy guard: converge() suspends several times, and a stale
    /// converge resuming after a newer one must not activate an outdated
    /// assertion or stamp an outdated concealed set. Each converge takes a
    /// ticket; any resume point where the ticket is no longer current aborts.
    private var convergeEpoch = 0
    /// When the last assertion swap was issued — teardown detection ignores
    /// the settle window right after a swap (items take a beat to drop out).
    private var lastSwapAt = Date.distantPast
    /// When one of Pelmet's own items last joined the bar (`ownItemShown`),
    /// and whether the walk at rest it is owed is still to come.
    private var ownShowAt = Date.distantPast
    private var ownShowOwed = false
    /// Bounded retries for converges that find an EMPTY AX walk. A real bar
    /// always contains system items, so empty means the agent tree isn't
    /// readable yet (launch, locked screen) — planning from it swaps in an
    /// allow-all assertion that un-hides everything for a beat.
    private var emptyAXRetriesRemaining = EngineTiming.emptyAXRetries
    /// Past the fast retries, a slow one keeps coming until the bar reads:
    /// nothing else walks at rest, and the bounded retries alone left a
    /// fresh launch un-hidden until the next hover (2026-10-08, 17s). Its
    /// delay backs off (`EngineTiming.emptyAXSlowRetry`); nil until the
    /// fast ones run out.
    private var emptyAXSlowDelay: Duration?
    /// The one pending retry, so converges that walk empty for other
    /// reasons don't each start a chain of their own.
    private var emptyAXRetry: Task<Void, Never>?
    private var emptyAXSince: Date?
    /// Retries stopped for a locked or switched-out session: nothing reads
    /// until it is back, and the unlock (or a wake) starts them over.
    private var emptyAXPaused = false
    /// Away by loginwindow's and the workspace's notifications. Retries stop
    /// only when this and the session dictionary agree, so a stale read on
    /// either side of an unlock can't leave them stopped for good.
    private var sessionAway = false
    private var sessionObservers: [(NotificationCenter, any NSObjectProtocol)] = []

    /// Timings of the most recent converge that ran to a decision (PerfTrace
    /// reads it right after `reveal`/`conceal` return).
    public private(set) var lastConvergeTiming: ConvergeTiming?
    private var timing = ConvergeTiming()

    private static func ms(since start: Date) -> Int {
        Int((-start.timeIntervalSinceNow * 1000).rounded())
    }

    public init() {
        var continuation: AsyncStream<EngineEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !started else { return }
        started = true
        observeSession()
        _ = await refreshSnapshot()
    }

    /// TERMINAL: finishing the event stream is irreversible, so the engine is
    /// single-use — one instance per app lifetime. `started` deliberately
    /// stays true so a later `start()` is a no-op instead of running with a
    /// dead stream.
    public func stop() async {
        for (center, token) in sessionObservers { center.removeObserver(token) }
        sessionObservers = []
        invalidateAssertion()
        // Ends any `for await` over `events` instead of hanging it forever.
        eventContinuation.finish()
    }

    // MARK: - MenuBarEngine

    public func snapshot() async -> EngineSnapshot {
        if let lastSnapshot, Date().timeIntervalSince(lastSnapshot.takenAt) < EngineTiming.snapshotTTL {
            return lastSnapshot
        }
        return await refreshSnapshot()
    }

    public func setModel(_ model: SectionModel) async {
        self.model = model
        await converge()
    }

    public func setSteadyExtras(_ enabled: Bool) async {
        guard steadyExtras != enabled else { return }
        steadyExtras = enabled
        await converge()
    }

    public func reveal(_ sections: Set<Section>) async {
        revealedSections.formUnion(sections)
        await converge()
    }

    /// `reveal` that also lets the assertion go, whatever stays assigned
    /// where (#106): MenuBarAgent takes every Live Activity pill off the bar
    /// under any assertion, allow-all included, so the pills only come back
    /// with none held. Everything the assertion hid comes back with them,
    /// Always Hidden and the system extras too. Converges in between keep it
    /// dropped; the conceal or narrow that ends the reveal takes it back in
    /// the same swap. Empty `sections` lifts a bar that is out already.
    public func reveal(_ sections: Set<Section>, liftingAssertion: Bool) async {
        if liftingAssertion, !lifted {
            lifted = true
            PelmetLog.log("lift: the assertion goes with the reveal — Live Activities back")
        }
        revealedSections.formUnion(sections)
        await converge()
    }

    /// Live mode: the assertion stays down across conceals and
    /// narrows, so the pill keeps showing while the bar reads concealed
    /// under the app's cover. Only `holdLift(false)` ends it.
    private var keepsLift = false

    /// Live mode's two ends: down, the assertion goes and stays gone;
    /// up, the assertion comes back in one swap.
    public func holdLift(_ on: Bool) async {
        if on {
            keepsLift = true
            if !lifted {
                lifted = true
                PelmetLog.log("lift: the assertion goes for live mode — Live Activities back")
            }
        } else {
            keepsLift = false
            endLift("live mode over")
        }
        await converge()
    }

    /// Live mode hands the bar to a normal reveal: the hold and the lift end
    /// with no converge of their own; the reveal's converge is the one swap
    /// (the assertion comes back with the sections' bundles allowed).
    public func releaseLiftHold() {
        keepsLift = false
        endLift("live mode handed to a reveal")
    }

    private func endLift(_ why: String) {
        guard lifted, !keepsLift else { return }
        lifted = false
        PelmetLog.log("lift: over (\(why)), the assertion comes back")
    }

    /// Take back every revealed section but these, the rest staying out:
    /// one swap. `reveal` only adds, so narrowing by a conceal and a fresh
    /// reveal reflowed the bar twice.
    public func narrowReveal(to sections: Set<Section>) async {
        endLift("narrow")
        revealedSections.formIntersection(sections)
        await converge()
    }

    /// Reveal these items only: their bundles leave the concealable set,
    /// every section stays as it is, nothing else reflows.
    public func reveal(items: Set<ItemID>) async {
        revealedItems.formUnion(items)
        companionMuted = true
        await converge()
        companionMuted = false
    }

    /// Put these items back after an item-only reveal. Sections revealed
    /// meanwhile (a hover) stay as they are.
    public func conceal(items: Set<ItemID>) async {
        revealedItems.subtract(items)
        companionMuted = true
        await converge()
        companionMuted = false
    }

    /// The items revealed on their own right now: a press's, or a picture
    /// pass's follow-up round.
    public func itemsRevealedOnTheirOwn() -> Set<ItemID> { revealedItems }

    /// The items out on their own right now, their section concealed (a
    /// show rule's, a press's): what the next snapshot stamps as `shownAlone`.
    public func itemsShownAlone() -> Set<ItemID> { shownAlone }

    /// The items show rules want on the bar right now. Sections stay as
    /// they are, like an item-only reveal.
    public func setRuleShown(_ items: Set<ItemID>) async {
        guard items != ruleShownItems else { return }
        ruleShownItems = items
        companionMuted = true
        await converge()
        companionMuted = false
    }

    public func conceal() async {
        await conceal(releasing: [])
    }

    /// `conceal()` that also takes back icons Show in Menu Bar brought out on
    /// their own, in one swap instead of two.
    public func conceal(releasing items: Set<ItemID>) async {
        endLift("conceal")
        revealedItems.subtract(items)
        // Nothing revealed but items: no section changes, the extras stay.
        companionMuted = revealedSections.isEmpty && !revealedItems.isEmpty
        revealedSections = []
        await converge()
        companionMuted = false
    }

    /// Bundle ids of the running applications, pushed by the app from its
    /// KVO on `NSWorkspace.runningApplications`.
    private var runningBundles: Set<String>?

    public func setRunningBundles(_ bundles: Set<String>) {
        runningBundles = bundles
    }

    public func quiesced(for interval: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastSwapAt) > interval
    }

    /// The mirror when it was walked at rest — `restWalkDelay` past the
    /// last swap, so the agent's reflow was over — and is recent enough
    /// (`restSnapshotReuse`). Nil means the bar may have changed since:
    /// walk. Only Pelmet's own swaps move the bar's contents on their own;
    /// app launches and user drags reach the mirror through the walks the
    /// app already runs for them.
    public var restSnapshot: EngineSnapshot? {
        guard let last = lastSnapshot, !last.items.isEmpty, last.itemsAtRest,
              last.takenAt.timeIntervalSince(lastSwapAt) >= EngineTiming.restWalkDelay,
              Date().timeIntervalSince(last.takenAt) < EngineTiming.restSnapshotReuse
        else { return nil }
        return last
    }

    /// Fresh registrations under ANY active assertion park offscreen and
    /// never enter the agent's AX tree (verified at boot — it's why start()
    /// waits for own-item adoption; re-verified live 2026-08-31: a relaunched
    /// Bitwarden stayed parked 4+ minutes). The swap choreography is
    /// deliberately gapless, so no adoption window ever occurs on its own.
    /// This opens one: drop the assertion, poll the walk until the bundle's
    /// item lands (parked items land instantly once no assertion holds),
    /// then re-converge. Cost: concealed items flash for the window's
    /// duration — callers keep it rare (app relaunch) and skip it when the
    /// bundle is already observable.
    ///
    /// `item`: the one live id the window is for. A section helper hosts
    /// several items under one bundle, so "any item of this bundle" is
    /// satisfied by a sibling that was adopted long ago and the window
    /// closes before the new registration lands (parked for the session).
    /// Whether a hide assertion is held right now. Callers use it to decide
    /// if an adoption window will actually drop anything worth covering —
    /// with none held `openAdoptionWindow` returns straight away and the
    /// bar never changes.
    public var holdsAssertion: Bool { assertion != nil }

    public func openAdoptionWindow(for bundleID: String, expecting item: ItemID? = nil) async -> Bool {
        guard assertion != nil else { return true }
        PelmetLog.log("adoptWindow: dropping assertion for \(item?.rawValue ?? bundleID)")
        invalidateAssertion()
        var adopted = false
        let deadline = Date().addingTimeInterval(EngineTiming.adoptionWindowDeadline)
        while Date() < deadline {
            let snap = await refreshSnapshot()
            let landed = item.map { id in snap.items.contains { $0.id == id } }
                ?? snap.items.contains { $0.id.bundleID == bundleID }
            if landed {
                adopted = true
                break
            }
            try? await Task.sleep(for: EngineTiming.adoptionWindowPoll)
        }
        PelmetLog.log("adoptWindow: \(bundleID) \(adopted ? "adopted" : "not seen") — re-asserting")
        await converge()
        return adopted
    }

    /// Desired left-to-right tag order: model order per section, sections
    /// laid out as [alwaysHidden][hidden][visible] (hidden sections collapse
    /// toward the left of the status area, matching the classic layout).
    /// Concealed items drop out of AX but are exactly the ones being ordered
    /// — union them in (frame nil sorts by explicit order only).
    private func desiredOrderedTags(from snapshot: EngineSnapshot) -> [String] {
        let liveIDs = Set(snapshot.items.map(\.id))
        let concealedItems = snapshot.concealed.subtracting(liveIDs).map {
            ObservedItem(id: $0, frame: nil, appName: nil)
        }
        let allItems = snapshot.items + concealedItems
        var orderedTags: [String] = []
        for section in [Section.alwaysHidden, .hidden, .visible] {
            let sectionItems = allItems
                .filter { model.section(of: $0.id) == section && !$0.id.isSystemModule }
            let explicit = model.order[section] ?? []
            let ranked = sectionItems.sorted { lhs, rhs in
                // Order arrays hold canonical section keys — rank real items
                // through the same lens.
                let li = explicit.firstIndex(of: lhs.id.sectionKey) ?? Int.max
                let ri = explicit.firstIndex(of: rhs.id.sectionKey) ?? Int.max
                if li != ri { return li < ri }
                // Fall back to current on-screen order (agent order);
                // frame-nil (concealed) items rank rightmost — the editor's
                // rule, pinned by EditorItemsBuilderTests.
                return (lhs.frame?.minX ?? .greatestFiniteMagnitude)
                    < (rhs.frame?.minX ?? .greatestFiniteMagnitude)
            }
            orderedTags.append(contentsOf: ranked.map(\.id.rawValue))
        }
        return orderedTags
    }

    /// Write the model's desired order to the agent plist WITHOUT restarting
    /// the agent. Live items ignore the plist entirely — their order lives in
    /// the client processes' own registrations (proven live 2026-08-21:
    /// plist writes + restarts + conceal/reveal cycles never re-slot a live
    /// item, while a real ⌘-drag survives agent restarts with no disk record)
    /// — but a FRESH registration (app relaunch, brand-new item) slots from
    /// it, so the hint keeps future spawns landing in model order.
    public func writeOrderHint() async {
        let snapshot = await refreshSnapshot()
        AgentPositionStore.writeOrder(desiredOrderedTags(from: snapshot))
    }

    // MARK: - Convergence

    /// The one path that changes hide state. Idempotent: computes the full
    /// allowlist from (model, revealedSections) and swaps the assertion in a
    /// single transition.
    private func converge() async {
        convergeEpoch += 1
        let epoch = convergeEpoch
        timing = ConvergeTiming()
        // Stamped whatever the outcome — a superseded converge reads
        // `superseded` rather than leaving the previous one's numbers
        // under the next perf line.
        defer { lastConvergeTiming = timing }
        var phase = Date()
        let snapshot: EngineSnapshot
        if let rest = restSnapshot {
            // The bar has not reflowed since this walk: plan from it. A
            // bundle that appeared since is caught by the walk behind the
            // swap, one converge later — the same window the app already
            // has between walks at rest.
            snapshot = rest
            timing.walkReused = true
        } else {
            snapshot = await refreshSnapshot()
        }
        timing.walkMS = Self.ms(since: phase)
        guard epoch == convergeEpoch else { return }
        if snapshot.items.isEmpty {
            timing.outcome = .emptyWalk
            deferEmptyWalkRetry()
            return
        }
        if let since = emptyAXSince {
            PelmetLog.log("converge: AX walk back after \(Self.ms(since: since))ms empty")
            emptyAXSince = nil
        }
        emptyAXRetriesRemaining = EngineTiming.emptyAXRetries
        emptyAXSlowDelay = nil
        emptyAXPaused = false
        // Running-app set: consulted by the stale prune below (quit apps) and
        // the allowlist build. Fetched once, up front.
        phase = Date()
        // The app keeps this set from its KVO on runningApplications; the
        // main-actor hop it replaced waited on a busy main thread (plan
        // read 1–19ms, 2026-09-21). Fetched once when nothing was pushed.
        let runningBundles: Set<String>
        if let known = self.runningBundles {
            runningBundles = known
        } else {
            runningBundles = await MainActor.run {
                Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            }
            self.runningBundles = runningBundles
        }
        guard epoch == convergeEpoch else { return }
        // The pure decision step — "existing" set (observed ∪ carried
        // concealed, drift-pruned), concealable bundles, system allowlist,
        // bundle allowlist, resulting concealed set. Logic + rationale live
        // in ConvergePlan.compute (unit-tested); this actor only executes.
        let plan = ConvergePlan.compute(
            model: model,
            liveIDs: Set(snapshot.items.map(\.id)),
            carriedConcealed: (lastSnapshot?.concealed ?? []).union(setAsideConcealed),
            runningBundles: runningBundles,
            revealedSections: revealedSections,
            revealedItems: revealedItems.union(ruleShownItems),
            steadyExtras: steadyExtras,
            lifted: lifted,
            exemptBundles: Self.identityExemptBundles
        )
        timing.planMS = Self.ms(since: phase)
        for (id, reason) in plan.stale {
            PelmetLog.log("converge: pruned concealed \(reason == .staleAlias ? "stale alias" : "entry for quit app") \(id.rawValue)")
        }

        guard AssessmentMode.isAvailable else {
            timing.outcome = .unavailable
            if assertion != nil { invalidateAssertion() }
            eventContinuation.yield(.availabilityChanged(false))
            return
        }

        if plan.dropAssertion {
            timing.outcome = .dropped
            await dropAssertionPath(plan: plan, snapshot: snapshot, epoch: epoch)
            return
        }
        // With steadyExtras on, an empty concealable set still holds an
        // assertion allowing every observed bundle — only the OS extras hide.
        await performSwap(plan: plan, snapshot: snapshot, epoch: epoch)
    }

    /// An empty AX walk can't be trusted: a real bar always has system
    /// items, so this is the agent tree not being readable yet (launch,
    /// locked screen). A plan computed from it has concealable=[] and
    /// would swap in an allow-all assertion — a momentary un-hide flash
    /// followed by a second animated swap when AX populates. Defer with fast
    /// retries, then slow ones until a walk reads: nothing else walks at
    /// rest, so a bound left the bar un-hidden until the next interaction.
    /// The slow ones keep 2s for the first two minutes of the run (a launch
    /// reads empty for up to 40s), then back off; they stop while the
    /// session is locked. 2s flat walked the agent tree all night (≈14k).
    private func deferEmptyWalkRetry() {
        if emptyAXSince == nil { emptyAXSince = Date() }
        guard emptyAXRetry == nil else { return }
        if sessionAway, Self.sessionDictionarySaysAway {
            if !emptyAXPaused {
                emptyAXPaused = true
                PelmetLog.log("converge: AX walk empty, screen locked — retries stop until unlock or wake")
            }
            return
        }
        let delay: Duration
        if emptyAXRetriesRemaining > 0 {
            PelmetLog.log("converge: AX walk empty — deferring (retries left \(emptyAXRetriesRemaining))")
            emptyAXRetriesRemaining -= 1
            delay = EngineTiming.emptyAXRetryDelay
        } else {
            let emptyFor = emptyAXSince.map { -$0.timeIntervalSinceNow } ?? 0
            delay = EngineTiming.emptyAXSlowRetry(after: emptyAXSlowDelay, emptyFor: emptyFor)
            if emptyAXSlowDelay == nil {
                PelmetLog.log("converge: AX walk still empty — retrying every \(delay) until the bar reads, backing off to \(EngineTiming.emptyAXSlowRetryMax) after \(Int(EngineTiming.emptyAXFlatRetryWindow))s")
            } else if delay != emptyAXSlowDelay {
                PelmetLog.log("converge: AX walk still empty — backing off to \(delay)")
            }
            emptyAXSlowDelay = delay
        }
        emptyAXRetry = Task {
            try? await Task.sleep(for: delay)
            // Cancelled by a restart that converges itself.
            guard !Task.isCancelled else { return }
            self.emptyAXRetry = nil
            await self.converge()
        }
    }

    // MARK: - Session (empty-walk retries)

    /// Lock, unlock, fast user switching and wake: the empty-walk retries
    /// stop while the session is away and start over when it is back.
    private func observeSession() {
        sessionAway = Self.sessionDictionarySaysAway
        func on(
            _ center: NotificationCenter, _ name: Notification.Name,
            _ handle: @escaping @Sendable (AgentBarEngine) async -> Void
        ) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { await handle(self) }
            }
            sessionObservers.append((center, token))
        }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { await $0.sessionAwayChanged(true, "screen locked") }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { await $0.sessionAwayChanged(false, "screen unlocked") }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { await $0.sessionAwayChanged(true, "session switched out") }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { await $0.sessionAwayChanged(false, "session back") }
        on(workspace, NSWorkspace.didWakeNotification) { await $0.restartEmptyWalkRetries("wake") }
        on(workspace, NSWorkspace.screensDidWakeNotification) { await $0.restartEmptyWalkRetries("displays woke") }
    }

    private func sessionAwayChanged(_ away: Bool, _ reason: String) async {
        sessionAway = away
        if !away { await restartEmptyWalkRetries(reason) }
    }

    /// A chain stopped for the lock, or backed off to a minute, starts over
    /// with fast retries, so the bar hides as soon as it reads again. The
    /// run restarts too: its flat 2s window counts from here, not from the
    /// lock (the "walk back" line then measures from here).
    private func restartEmptyWalkRetries(_ reason: String) async {
        guard let since = emptyAXSince else { return }
        emptyAXRetry?.cancel()
        emptyAXRetry = nil
        emptyAXPaused = false
        emptyAXRetriesRemaining = EngineTiming.emptyAXRetries
        emptyAXSlowDelay = nil
        emptyAXSince = Date()
        PelmetLog.log("converge: \(reason) after \(Self.ms(since: since))ms of empty walks — retrying")
        await converge()
    }

    /// Locked or switched to another user, as the session dictionary has it
    /// (the same read as the app's Apply gate).
    private static var sessionDictionarySaysAway: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
            || (session[kCGSessionOnConsoleKey as String] as? Bool) == false
    }

    /// Nothing to hide and extras are allowed back: drop the assertion.
    private func dropAssertionPath(plan: ConvergePlan, snapshot: EngineSnapshot, epoch: Int) async {
        invalidateAssertion()
        notifyReflowCompanion()
        if lifted {
            // A lift's walk blocks on the agent's reflow, and this one brings
            // every icon and extra back: the reveal settled 683–734ms after
            // the drop (2026-10-27), the rehide countdown and a second click
            // waiting on it. Stamped and walked behind, as a swap is: nothing
            // is concealed now, and the items the drop brings are not in the
            // mirror yet, so it is not at rest.
            setAsideConcealed = plan.setAside
            lastSnapshot = EngineSnapshot(
                items: snapshot.items, concealed: [], takenAt: Date(), shownAlone: shownAlone, itemsAtRest: false
            )
            Task { await self.walkAfterSwap(concealable: [], epoch: epoch, what: "drop") }
            return
        }
        let after = await refreshSnapshot()
        guard epoch == convergeEpoch else { return }
        setAsideConcealed = plan.setAside
        // Nothing is concealed now — clearing the carried set here stops
        // observers from reporting phantom concealment until the next swap.
        lastSnapshot = EngineSnapshot(
            items: after.items,
            concealed: [],
            takenAt: after.takenAt,
            itemsAtRest: after.itemsAtRest
        )
    }

    /// The swap half of converge: teardown detection, the idempotence no-op
    /// guard, assertion activation (activate new THEN invalidate previous),
    /// snapshot stamping, and the off-critical-path verify kickoff.
    private func performSwap(plan: ConvergePlan, snapshot: EngineSnapshot, epoch: Int) async {
        let concealable = plan.concealable
        let allowedSystem = plan.allowedSystem
        let allowedBundles = plan.allowedBundles

        // Teardown detection: a concealable bundle observed LIVE while our
        // bookkeeping claims a matching assertion means macOS dropped the
        // assertion externally — without this, the itemsChanged the
        // reappearance triggers converges straight into the no-op guard and
        // the wedge is permanent. Only trust the signal once the post-swap
        // settle window (verify covers 3s) has passed, or the normal AX
        // drop-out latency right after a swap would read as a violation.
        // Gated on a live assertion: with none held, `lastSwapAt` is still
        // .distantPast on a cold boot and the pre-assert bar (everything
        // visible) read as a teardown — a spurious .assertionTornDown +
        // wasted converge on every launch.
        let assertionLost = assertion != nil
            && Date().timeIntervalSince(lastSwapAt) > EngineTiming.teardownSettleWindow
            && snapshot.items.contains { item in
                guard let bundle = item.id.bundleID else { return false }
                return concealable.contains(bundle)
            }

        // Idempotence: an equivalent state under a live assertion = already
        // converged. Skip the swap — this is what breaks event feedback loops.
        // Superset check (not equality): an app quitting leaves a harmless
        // stale allow entry and must not cause a swap; a NEW bundle missing
        // from the active allowlist must.
        if assertion != nil, !assertionLost,
           activeConcealable == concealable,
           activeSystemAllow == Set(allowedSystem.map(\.rawValue)),
           let activeAllowlist, activeAllowlist.isSuperset(of: allowedBundles) {
            timing.outcome = .noop
            PelmetLog.log("converge: no-op (concealable=\(concealable.count), allow=\(allowedBundles.count))")
            // The assertion stands, but the bookkeeping may not: a carried
            // id whose section is now revealed is no longer concealed, and
            // left stamped it drew a ghost tile in the editor (Apple's Siri
            // and Time Machine switched off under a revealed Hidden section,
            // 2026-09-16 — SystemUIServer runs forever, so nothing else
            // ever pruned them).
            if let last = lastSnapshot, last.concealed != plan.concealed {
                lastSnapshot = EngineSnapshot(
                    items: snapshot.items, concealed: plan.concealed, takenAt: snapshot.takenAt, shownAlone: shownAlone,
                    itemsAtRest: snapshot.itemsAtRest
                )
            }
            setAsideConcealed = plan.setAside
            return
        }
        if assertionLost {
            PelmetLog.log("converge: concealable items visible under live bookkeeping — assertion lost, re-swapping")
            eventContinuation.yield(.assertionTornDown)
        }
        PelmetLog.log("converge: swapping — concealable=\(concealable.sorted()), allow=\(allowedBundles.count), revealed=\(revealedSections.count), live=\(snapshot.items.count), carried=\(lastSnapshot?.concealed.count ?? -1), assigns=\(model.assignments.count)")

        let previous = assertion
        // Bounded wait: the completion is async (and can be a dud) — a stuck
        // activation must never wedge the converge path. 3s is generous; the
        // observed completion latency is <100ms.
        let activationBox = ActivationBox()
        let activateStarted = Date()
        let handle = AssessmentMode.activate(allowing: allowedSystem, bundleIDs: Array(allowedBundles)) { error in
            activationBox.resolve(error == nil)
        }
        // Companion items change size NOW so the agent coalesces their reflow
        // with the assertion swap it's about to animate.
        notifyReflowCompanion()

        guard let handle else {
            // No handle at all: keep the previous assertion alive (it still
            // holds SOME hide state) and leave bookkeeping pointing at it —
            // the next converge toward this target won't match the no-op
            // guard, so retrying stays possible. Invalidating `previous` here
            // used to kill the still-current assertion and wedge the state.
            timing.outcome = .activationNil
            PelmetLog.log("converge: activation returned nil handle — keeping previous assertion")
            eventContinuation.yield(.convergeFailed("assertion activation failed"))
            return
        }
        assertion = handle
        activeAllowlist = allowedBundles
        activeConcealable = concealable
        activeSystemAllow = Set(allowedSystem.map(\.rawValue))
        lastSwapAt = Date()
        // Resumed by the completion the moment it lands (measured 2026-09-21:
        // the old 50ms poll made every swap read 50–55ms) or by the deadline.
        let activated = await activationBox.wait(deadline: .seconds(EngineTiming.activationDeadline))
        timing.activateMS = Self.ms(since: activateStarted)
        timing.activated = activated
        // Swap order matters: activate the new state, then drop the old
        // assertion so there is no flash of everything-visible in between.
        let invalidateStarted = Date()
        previous?.invalidate()
        timing.invalidateMS = Self.ms(since: invalidateStarted)
        guard epoch == convergeEpoch else { return }

        if !activated {
            PelmetLog.log("converge: assertion activation FAILED (dud completion)")
            // The handle exists but activation never confirmed — the real hide
            // state is unknown. Drop the allowlist bookkeeping so the next
            // converge fails the no-op guard and re-swaps instead of wedging.
            activeAllowlist = nil
            eventContinuation.yield(.convergeFailed("assertion activation failed"))
        } else {
            PelmetLog.log("converge: assertion active")
        }
        // Stamp the concealed set NOW — observers must union it from the
        // moment the swap is issued — on the pre-swap items: the post-swap
        // walk blocks on the agent's reflow (measured 2026-09-21: 53–193ms,
        // longer the sooner it starts) and holding converge for it held the
        // settle report, the rehide countdown and every queued transition.
        // The walk runs behind the swap instead and refreshes the mirror
        // when it lands (it fires itemsChanged as it always did).
        timing.outcome = .swapped
        // Stamped with the swap time, not the mirror's: `snapshot()` reads
        // it inside its TTL right after the swap instead of walking
        // mid-reflow (a 200ms walk on the settle path, 2026-09-21 11:05),
        // and `restSnapshot` stays nil until a walk at rest replaces it.
        // Not at rest: the icons the swap revealed are not in the items yet
        // (a pending reorder cleared on it, live test 2026-10-13).
        lastSnapshot = EngineSnapshot(
            items: snapshot.items,
            concealed: plan.concealed,
            takenAt: Date(),
            shownAlone: shownAlone,
            itemsAtRest: false
        )
        setAsideConcealed = plan.setAside
        Task { await self.walkAfterSwap(concealable: concealable, epoch: epoch) }
    }

    /// An item press found no icon for `key` with the native « expanded,
    /// which hides nothing then: its app removed it. Out of the carried
    /// and the set-aside sets, so no conceal stamps it again and its tile
    /// goes; kept, it stood until the app quit (review B5).
    public func forget(_ key: ItemID) {
        let key = key.sectionKey
        PelmetLog.log("converge: let go of \(key.rawValue) — pressed with the « expanded and not on the bar")
        setAsideConcealed = setAsideConcealed.filter { $0.sectionKey != key }
        if let last = lastSnapshot, last.concealed.contains(where: { $0.sectionKey == key }) {
            lastSnapshot = EngineSnapshot(
                items: last.items,
                concealed: last.concealed.filter { $0.sectionKey != key },
                takenAt: last.takenAt,
                shownAlone: last.shownAlone,
                itemsAtRest: last.itemsAtRest
            )
        }
    }

    /// The post-swap walk, off the critical path. It is the verify's first
    /// poll: when it already shows every concealable bundle gone there is
    /// nothing to poll for. A newer converge owns the state (and walks for
    /// itself) once the epoch has moved.
    private func walkAfterSwap(concealable: Set<String>, epoch: Int, what: String = "swap") async {
        guard epoch == convergeEpoch else { return }
        let started = Date()
        let after = await refreshSnapshot()
        PelmetLog.log("converge: post-\(what) walk \(Self.ms(since: started))ms (background)")
        guard epoch == convergeEpoch else { return }
        let stillVisible = after.items.contains { item in
            guard let bundle = item.id.bundleID else { return false }
            return concealable.contains(bundle)
        }
        if stillVisible {
            await verifyConcealment(of: concealable)
        }
    }

    /// A walk that ran inside the reflow can list half the strip (AX adds
    /// freshly revealed items progressively). One more at rest makes the
    /// mirror whole, so the next transition can plan and measure from it
    /// instead of walking (`restSnapshot`), and the settle can judge.
    /// Scheduled by any mirror not at rest (`lastSnapshot`), never gated on
    /// a converge's epoch: the itemsChanged the post-swap walk fires runs a
    /// no-op converge (a new epoch) before the bar is at rest, and a swap a
    /// newer converge overtook never stamps. A newer swap moves
    /// `lastSwapAt`, so the wait below simply extends to that one's rest.
    private func scheduleRestWalk() {
        guard !restWalkScheduled else { return }
        restWalkScheduled = true
        Task { await self.walkAtRest() }
    }

    /// One of Pelmet's own items joined the bar. One outside a swap (a
    /// Timer counting, media or the camera coming on, Show in Menu Bar)
    /// gets no stamp, so no walk at rest reads it, and the Apply count
    /// waits on that walk for a drop of it: "Apply (1)" stayed until the
    /// next transition (review, 2026-10-13). This owes it one, half a second
    /// on, coalesced with any walk at rest already pending (one riding a
    /// swap costs nothing more), and announced even when the mirror was at
    /// rest already.
    public func ownItemShown() {
        ownShowAt = Date()
        ownShowOwed = true
        scheduleRestWalk()
    }

    private func walkAtRest() async {
        func untilRest() -> TimeInterval {
            EngineTiming.restWalkDelay - Date().timeIntervalSince(max(lastSwapAt, ownShowAt))
        }
        var wait = untilRest()
        while wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            wait = untilRest()
        }
        // Cleared before the walk: a swap that lands during it writes a
        // stamp that schedules the next one, and a show owes the next one.
        restWalkScheduled = false
        let owed = ownShowOwed
        ownShowOwed = false
        guard restSnapshot == nil || owed else { return }
        let wasAtRest = lastSnapshot?.itemsAtRest
        let restStarted = Date()
        let snapshot = await refreshSnapshot()
        PelmetLog.log("converge: rest walk \(Self.ms(since: restStarted))ms (background)")
        // `refreshSnapshot` announces a mirror coming to rest; one at rest
        // already is announced here, for the show.
        if owed, snapshot.itemsAtRest, wasAtRest != false {
            eventContinuation.yield(.mirrorAtRest)
        }
    }

    /// Background verify-after-apply: bounded poll until the concealed
    /// bundles drop out of the AX tree. Bails silently when a newer converge
    /// has superseded this one — that converge owns the state now.
    private func verifyConcealment(of concealable: Set<String>) async {
        let deadline = Date().addingTimeInterval(EngineTiming.verifyWindow)
        while Date() < deadline {
            try? await Task.sleep(for: EngineTiming.verifyPoll)
            guard activeConcealable == concealable else { return }
            let check = await refreshSnapshot()
            let stillVisible = check.items.contains { item in
                guard let bundle = item.id.bundleID else { return false }
                return concealable.contains(bundle)
            }
            if !stillVisible { return }
        }
        guard activeConcealable == concealable else { return }
        PelmetLog.log("converge: STILL VISIBLE after verify window")
        // The assertion claims these bundles are hidden but reality disagrees
        // (dud activation, or macOS tore the assertion down externally). Drop
        // the allowlist bookkeeping so the next converge re-swaps instead of
        // no-op'ing against bookkeeping that no longer reflects the bar.
        activeAllowlist = nil
        eventContinuation.yield(.convergeFailed("concealed items still visible after verify window"))
    }

    /// Thread-safe one-shot for the assertion completion (delivered on an
    /// arbitrary queue by the private framework, possibly late, possibly
    /// never, possibly twice). The first `resolve` wins; `wait` resumes on
    /// it at once, or with `false` at the deadline — a dud completion that
    /// lands after the deadline is ignored, as before.
    private final class ActivationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        private var waiter: CheckedContinuation<Bool, Never>?

        func resolve(_ success: Bool) {
            lock.lock()
            guard value == nil else { lock.unlock(); return }
            value = success
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: success)
        }

        func wait(deadline: Duration) async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let value {
                    lock.unlock()
                    continuation.resume(returning: value)
                    return
                }
                waiter = continuation
                lock.unlock()
                Task {
                    try? await Task.sleep(for: deadline)
                    self.resolve(false)
                }
            }
        }
    }

    // MARK: - Clock blink

    /// Drop the live assertion so a clock click can reach Notification
    /// Center (ControlCenter refuses it under ANY visibility restriction —
    /// probe-proven 2026-09-03, no origin or allowlist escapes it). Returns
    /// false when nothing was held, in which case the click needs no help.
    /// Synchronous inside the actor: the caller posts the click the moment
    /// this returns, and the invalidate XPC is already queued ahead of it.
    /// Bumps the converge epoch so an in-flight converge can't re-assert
    /// between the drop and the click.
    public func beginClockBlink(label: String = "clock") -> Bool {
        guard assertion != nil else { return false }
        convergeEpoch += 1
        invalidateAssertion()
        PelmetLog.log("\(label): blink — assertion dropped for the click")
        return true
    }

    /// Re-acquire after the click landed. Bookkeeping was cleared by the
    /// drop, so a plain converge fails the no-op guard and swaps back in.
    /// (The reflow's own itemsChanged may have converged already; then this
    /// is the no-op.) NC stays open through the re-acquire — verified.
    public func endClockBlink() async {
        await converge()
    }

    /// Visibility oracle for the blink cover: a fresh AX walk (the cached
    /// snapshot is up to 0.5s old) — true while any item of a bundle the
    /// live assertion conceals is still in the agent's tree. The bundle set,
    /// not the snapshot's stamped ids: a converge that lost its epoch to a
    /// hover reveal leaves the stamp stale (2026-09-14).
    /// A fresh AX walk, bypassing the snapshot cache.
    public func freshSnapshot() async -> EngineSnapshot {
        await refreshSnapshot()
    }

    /// Every copy of each item the last walk named, one per display's bar:
    /// the snapshot keeps the main display's alone. A press made from
    /// another display clicks the copy on that display's bar (#26).
    public func barCopies() async -> [ItemID: [CGRect]] {
        await enumerator.barCopies()
    }

    public func concealedItemsStillVisible() async -> Bool {
        guard let concealable = activeConcealable, !concealable.isEmpty else { return false }
        let snap = await refreshSnapshot()
        return snap.items.contains { $0.id.bundleID.map(concealable.contains) ?? false }
    }

    private func invalidateAssertion() {
        if assertion != nil {
            // Dropping an assertion reflows the bar exactly like a swap —
            // stamp lastSwapAt so quiesced() goes false and overlay covers
            // hold through the drop's animation instead of lifting mid-slide.
            lastSwapAt = Date()
        }
        assertion?.invalidate()
        assertion = nil
        activeAllowlist = nil
        activeConcealable = nil
        activeSystemAllow = nil
    }

    private func refreshSnapshot() async -> EngineSnapshot {
        let started = Date()
        let raw = await enumerator.snapshotItems()
        let previousIDs = lastSnapshot.map { Set($0.items.map(\.id)) }
        // Judged against the swap as it stands when the walk lands: one in
        // flight when a swap was issued read the bar before it, and landing
        // after the stamp it put pre-swap items over the post-swap concealed
        // set (review of N1, 2026-10-13).
        let snapshot = EngineSnapshot(
            items: raw.map {
                ObservedItem(id: $0.id, frame: $0.frame, appName: $0.appName, hostIsBundleless: $0.hostIsBundleless, pid: $0.pid)
            },
            concealed: lastSnapshot?.concealed ?? [],
            takenAt: Date(),
            shownAlone: shownAlone,
            itemsAtRest: EngineTiming.walkAtRest(startedAt: started, lastSwapAt: lastSwapAt)
        )
        if let previousIDs, previousIDs != Set(raw.map(\.id)) {
            eventContinuation.yield(.itemsChanged)
        }
        // A walk at rest can list the same icons as the stamp or the
        // reflow walk before it, and itemsChanged stays quiet then: the app
        // kept judging from the mirror that was not at rest.
        if lastSnapshot?.itemsAtRest == false, snapshot.itemsAtRest {
            eventContinuation.yield(.mirrorAtRest)
        }
        lastSnapshot = snapshot
        return snapshot
    }
}
