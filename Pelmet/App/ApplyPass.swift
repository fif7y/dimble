// ApplyPass.swift
// M1 of the sets core (docs/CORE-SETS.md): the one door through which
// Pelmet moves a bar item. Reads the bar, asks `MovePlan` for the fewest
// drags, waits for the pointer to be idle, then performs each `Move` as one
// shielded ⌘-drag (cursor hidden, physical input swallowed — `ItemMover`)
// and verifies the landing by order. Reports per item; failed moves stay
// pending so the button can offer Retry.

import AppKit
import PelmetCore
import PelmetEngine

struct ApplyReport: Equatable {
    struct Skipped: Equatable {
        let item: ItemID
        let why: MovePlan.Skip
    }
    var applied: [ItemID] = []
    var failed: [ItemID] = []
    var skipped: [Skipped] = []
    var planned = 0
    /// A grouping pass that gave up before its first drag because the user
    /// was typing or pointing again: nothing moved, nothing was spent.
    var abandoned = false
}

@MainActor
enum ApplyPass {
    /// A host the agent pins to the trailing cluster, or a system module.
    /// The input menu is movable; it must not become the trailing clamp
    /// when the agent re-registers it to the left of the chevron.
    static func isProtectedSystemItem(_ id: ItemID) -> Bool {
        if id.bundleID == PelmetBundle.textInputAgentID { return false }
        return MenuBarPolicy.isPositionPinnedAppleBundle(id.bundleID) || id.isSystemModule
    }

    /// Primary-band frames by canonical key, leftmost representative per
    /// key (title-variant twins collapse the same way the editor does).
    static func primaryFrames(_ snap: EngineSnapshot, appState: AppState) -> [ItemID: CGRect] {
        var frames = leftmostPrimaryFrames(snap)
        // Items the native « holds report overlapping phantom frames (one
        // shared minX, or staggered a few points apart; see
        // `PlacementGeometry.overflowTrapped`). They are not on screen:
        // dragging them "bounced" and marked Velja immovable (20:43,
        // 2026-09-20); staggered ones slipped through and every Apply
        // aimed into the « (13:36, 2026-09-21). Drop them here so no
        // plan, count or verify sees them.
        for key in trappedKeys(in: frames, drawn: appState.drawnNow(in: snap)) { frames.removeValue(forKey: key) }
        return frames
    }

    private static func leftmostPrimaryFrames(_ snap: EngineSnapshot) -> [ItemID: CGRect] {
        let maxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        var frames: [ItemID: CGRect] = [:]
        for item in snap.items {
            guard let f = item.frame, PlacementGeometry.isPrimary(f, screenMaxX: maxX) else { continue }
            let key = item.id.sectionKey
            if let existing = frames[key], existing.minX <= f.minX { continue }
            frames[key] = f
        }
        return frames
    }

    /// Keys whose primary-band frame overlaps another's: the «'s phantom,
    /// on the bar but not on screen. A frame the bar no longer draws
    /// (`AppState.drawnNow`) never makes a drawn one read as one.
    private static func trappedKeys(in frames: [ItemID: CGRect], drawn: (ItemID) -> Bool) -> Set<ItemID> {
        let entries = Array(frames)
        let trapped = PlacementGeometry.overflowTrapped(entries.map(\.value), drawn: entries.map { drawn($0.key) })
        return Set(trapped.map { entries[$0].key })
    }

    /// Items behind the « right now, by canonical key.
    static func trapped(_ snap: EngineSnapshot, appState: AppState) -> Set<ItemID> {
        trappedKeys(in: leftmostPrimaryFrames(snap), drawn: appState.drawnNow(in: snap))
    }

    /// Drawn entries the plan skipped as notOnScreen that are not on the bar
    /// at all (the app quit, the icon left): nothing to wait for, so they
    /// leave the report — or Apply stays lit on "1 not moved" forever
    /// (Sconce, 13:46 2026-09-21). Icons behind the « stay: they are on the
    /// bar and a later pass reaches them.
    /// An own item's skip stays: missing from the walk means not laid out
    /// yet (a locked screen reads empty), and the skip is what runs
    /// `placeOwnItemNow`'s retry ladder. Dropped, the media control lost its
    /// placement on every track change under a lock (2026-10-06).
    static func dropAbsentSkips(_ report: inout ApplyReport, snap: EngineSnapshot, scope: Scope) {
        if case .ownItem = scope { return }
        let onBar = Set(snap.items.map { $0.id.sectionKey })
        let absent = report.skipped.filter { $0.why == .notOnScreen && !onBar.contains($0.item.sectionKey) }
        guard !absent.isEmpty else { return }
        for skip in absent { PelmetLog.log("apply: \(skip.item.rawValue) is not on the bar — edit dropped") }
        report.skipped.removeAll { skip in absent.contains { $0.item == skip.item } }
    }

    /// Trapped icons a drawn edit names — the only reason a pass expands
    /// the « (Gab, 2026-09-21: never for moves that do not need it).
    static func trappedEdited(_ snap: EngineSnapshot, edits: OrderEdits, appState: AppState) -> Set<ItemID> {
        let drawn = Set(edits.order.values.flatMap { $0 })
        return trapped(snap, appState: appState).intersection(drawn)
    }

    /// `primaryFrames` plus the last frame remembered for each item that is
    /// concealed right now — the collapsed-bar view of the whole bar, for
    /// the Apply count (a wrong-side icon lights the button without a
    /// reveal). The pass itself measures live.
    static func rememberedFrames(_ snap: EngineSnapshot, appState: AppState) -> [ItemID: CGRect] {
        // Own extras in a concealed section are leaving the layout
        // (StatusItemFader: collapsed at 0.26s, gone at 0.7s). The walk after
        // a conceal reads them beside the chevron, their concealed neighbours
        // gone: that snapshot put Siri right of Snib, and every drop into
        // Hidden until the next reveal drew it last (2026-09-25).
        let revealed = appState.revealedSectionsForExtras
        let roster = appState.settings.sectionModel.roster
        var frames = primaryFrames(snap, appState: appState).filter { key, _ in
            guard MenuBarPolicy.isPelmetExtraID(key) else { return true }
            let section = roster.section(of: key)
            return section == .visible || revealed.contains(section)
        }
        // An icon out on its own sits beside the chevron, not in its slot:
        // it counts where it was last seen in place, like a concealed one.
        // Read live, a picture pass round lit Apply (2) for Velja and Pure
        // Paste with the editor open (2026-10-12 23:30).
        let alone = Set(snap.shownAlone.map(\.sectionKey))
        for key in alone { frames.removeValue(forKey: key) }
        let live = Set(snap.items.filter { $0.frame != nil }.map(\.id.sectionKey)).subtracting(alone)
        let chevronNow = appState.pelmetChevronItem(in: snap).flatMap { frames[$0.id.sectionKey]?.midX }
        var rememberedAlwaysHidden = Set<ItemID>()
        for id in snap.concealed.union(snap.shownAlone) {
            let key = id.sectionKey
            // One the swap just concealed stays listed on top of its
            // neighbour, a phantom `primaryFrames` drops: read as live it had
            // no place at all, and a drop into a concealed Hidden was left to
            // Apply (Vorssaint listed and remembered at 1597, 2026-10-13
            // 22:47:02). Own extras keep their rule above.
            if live.contains(key), frames[key] != nil || MenuBarPolicy.isPelmetExtraID(key) { continue }
            guard var f = appState.rememberedFrames[key] else { continue }
            // Concealed icons slide with the chevron: re-anchor the frame
            // to where the chevron is now (AppState.rememberedChevronMidX).
            if let now = chevronNow, let then = appState.rememberedChevronMidX[key] {
                f = f.offsetBy(dx: now - then, dy: 0)
            }
            frames[key] = f
            if roster.section(of: key) == .alwaysHidden { rememberedAlwaysHidden.insert(key) }
        }
        let hiddenLeft = frames.filter { roster.section(of: $0.key) == .hidden }.map(\.value.minX).min()
        let apart = FrameMemory.alwaysHiddenApart(
            in: frames, remembered: rememberedAlwaysHidden, concealed: Set(snap.concealed.map(\.sectionKey)),
            section: { roster.section(of: $0) }
        )
        return FrameMemory.alwaysHiddenLeftOfHidden(
            frames, alwaysHidden: apart, hiddenLeft: hiddenLeft, chevronMidX: chevronNow
        )
    }

    /// The bar as `MovePlan` wants it: canonical keys, left to right, only
    /// items with a primary-band frame.
    static func barOrder(_ frames: [ItemID: CGRect]) -> [ItemID] {
        frames.sorted { $0.value.minX < $1.value.minX }.map(\.key)
    }

    /// Icons on the bar their section's stored order doesn't list yet.
    private static func unlisted(in facts: BarFacts, appState: AppState) -> Set<ItemID> {
        let order = appState.settings.sectionModel.order
        return Set(facts.bar.filter { $0 != facts.chevron && order[facts.roster.section(of: $0)]?.contains($0) != true })
    }

    /// What both the plan and the stray check read off the bar.
    private struct BarFacts {
        let bar: [ItemID]
        let roster: Roster
        let chevron: ItemID?
        let pinned: Set<ItemID>
    }

    private static func barFacts(
        for appState: AppState, snapshot snap: EngineSnapshot, remembered: Bool, naming named: Set<ItemID> = []
    ) -> BarFacts {
        let frames = remembered ? rememberedFrames(snap, appState: appState) : primaryFrames(snap, appState: appState)
        // An icon no section holds is in no order, and no side is wrong for
        // it: the recording pill up left of the chevron was dragged twice as
        // a Visible stray (2026-10-22 09:13), and once moved past the
        // chevron it lit Apply for the icon it sat before. Only a pass that
        // names it sees it (`AppState.placeRecordingPill`).
        let bar = barOrder(frames).filter { !MenuBarPolicy.isSectionlessSystemIcon($0) || named.contains($0) }
        let chevron = appState.pelmetChevronItem(in: snap)?.id.sectionKey
        // The trailing system cluster only pins while it IS the cluster:
        // right of the chevron. A system item the user parked left of it
        // (hidden, or just dropped into Visible in the editor) moves like
        // any icon (Sound, 2026-09-20 16:56 and 17:00).
        let roster = appState.settings.sectionModel.roster
        let chevronMidX = chevron.flatMap { frames[$0]?.midX }
        func inTrailingCluster(_ id: ItemID) -> Bool {
            guard let chevronMidX, let x = frames[id]?.midX else { return roster.section(of: id) == .visible }
            return x > chevronMidX
        }
        // …and only while the roster still wants it there: Sound drawn into
        // Hidden while sitting right of the chevron was skipped as pinned on
        // every pass, "Moved 0" with Apply (1) coming back (2026-09-20 21:03).
        let pinned = Set(bar.filter {
            appState.isImmovable($0)
                || (isProtectedSystemItem($0) && inTrailingCluster($0)
                    && roster.section(of: $0) == .visible)
        })
        return BarFacts(bar: bar, roster: roster, chevron: chevron, pinned: pinned)
    }

    /// Pelmet's own items on the bar (extras, separators, replicas, the
    /// chevron): placed through their own scope and Apply, never by the
    /// grouping policy.
    private static func ownKeys(in bar: [ItemID]) -> Set<ItemID> {
        Set(bar.filter { $0.bundleID.map(PelmetBundle.ownIDs.contains) ?? false })
    }

    /// Icons whose side of the chevron disagrees with their section right
    /// now, left to right (docs/CORE-SETS.md §Keep sections grouped). Read
    /// the same way the Apply count reads the bar: remembered frames
    /// stand in for concealed icons.
    static func strays(
        for appState: AppState, snapshot snap: EngineSnapshot, remembered: Bool = true
    ) -> [ItemID] {
        let facts = barFacts(for: appState, snapshot: snap, remembered: remembered)
        return MovePlan.strays(
            bar: facts.bar, roster: facts.roster, chevron: facts.chevron,
            pinned: facts.pinned, exempt: ownKeys(in: facts.bar)
        )
    }

    /// One look at every icon the snapshot knows, for `StrayLedger`: its
    /// side of the chevron on the (remembered) primary bar, its section and
    /// the process behind it. The pid is what tells a relaunch from an icon
    /// that stayed.
    static func sightings(for appState: AppState, snapshot snap: EngineSnapshot) -> [StrayLedger.Sighting] {
        let facts = barFacts(for: appState, snapshot: snap, remembered: true)
        var pids: [ItemID: Int32] = [:]
        for item in snap.items where item.pid > 0 { pids[item.id.sectionKey] = item.pid }
        // A concealed system icon (Sound) can leave the engine's concealed
        // set too, as a stale alias: unlisted, the ledger forgot that the user
        // had placed it by hand, met it again as newly seen, and the grouper
        // dragged it back. Every member of a running app stays known.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let members = facts.roster.members.keys.filter { $0.bundleID.map(running.contains) ?? false }
        let concealed = Set(snap.concealed.map(\.sectionKey))
        let known = Set(snap.items.map(\.id.sectionKey))
            .union(concealed)
            .union(facts.bar)
            .union(members.map(\.sectionKey))
        return known.compactMap { id in
            guard id != facts.chevron else { return nil }
            return StrayLedger.Sighting(
                id: id,
                side: StrayLedger.side(of: id, in: facts.bar, chevron: facts.chevron),
                section: facts.roster.section(of: id),
                pid: pids[id],
                concealed: concealed.contains(id)
            )
        }
    }

    /// `strays` plans the grouping policy's pass instead: only the listed
    /// strays move (every other icon, strays Pelmet has no explanation for
    /// included, is an anchor) and the drawing is read for them alone: a
    /// stray the editor drew lands in its drawn slot.
    static func plan(
        for appState: AppState, snapshot snap: EngineSnapshot, edits: OrderEdits? = nil,
        remembered: Bool = false, strays allowed: Set<ItemID>? = nil, anchorUnlisted: Bool = false
    ) -> MovePlan.Plan {
        let facts = barFacts(for: appState, snapshot: snap, remembered: remembered, naming: allowed ?? [])
        if let allowed {
            return MovePlan.strayPlan(
                bar: facts.bar, roster: facts.roster, chevron: facts.chevron,
                pinned: facts.pinned, exempt: Set(facts.bar).subtracting(allowed),
                edits: edits ?? appState.settings.orderEdits
            )
        }
        // The one anchor is the chevron (passed separately). Every other own
        // item — extras, replicas, launchers, separators — drags like any
        // icon: registration never places an own item (a separator moved to
        // the end of Hidden in the editor re-hosted at the far right and
        // Apply skipped it as an anchor, 2026-09-20 20:19).
        var own = Set<ItemID>()
        // The keeper's view (M4): an icon its section's order doesn't list
        // has no stored slot, so it holds still and nothing listed is moved
        // around it (review, 2026-10-20).
        if anchorUnlisted { own = unlisted(in: facts, appState: appState) }
        // The whole bar against the editor's stored order, every section
        // (the editor owns the order, 2026-10-20): drift since the last drag
        // is a move like a drawing. Drawn only, Wi-Fi among Hidden and the
        // Always Hidden separator right of the « were nobody's to move.
        var plan = MovePlan.compute(
            bar: facts.bar,
            edits: edits ?? appState.editorOrderTarget,
            roster: facts.roster,
            chevron: facts.chevron,
            pinned: facts.pinned,
            ownItems: own
        )
        // The stored order lists every icon, so the plan skips every one it
        // has no frame for. Only a drawn one is something Apply didn't do:
        // two concealed Always Hidden icons nobody drew left "2 not moved"
        // up with nothing to retry (2026-10-20).
        if edits == nil {
            let drawn = Set(appState.settings.orderEdits.order.values.joined())
            plan.skipped.removeAll { !drawn.contains($0.0) }
        }
        return plan
    }

    /// Seconds since the last physical pointer event (public CGEventSource
    /// counters; our own synthetic events count too, which is fine — the
    /// pass only asks before its first drag).
    static func secondsSincePointerActivity() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    /// Seconds since the last input of any kind, keyboard included (a
    /// grouping pass hands the foreground to the dragged icon's app, which
    /// would take the user's keystrokes mid-sentence).
    static func secondsSinceAnyInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// False when the drag is put off: a mouse button is held and the pass
    /// is not one the user asked for (`PointerBorrow`, #159).
    private static func waitForIdlePointer(upTo wait: TimeInterval = AppTiming.applyIdleMaxWait, askedByUser: Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(wait)
        while true {
            let verdict = PointerBorrow.verdict(
                quietFor: secondsSincePointerActivity(), gap: AppTiming.applyIdleGap,
                buttonDown: NSEvent.pressedMouseButtons != 0, waitedOut: Date.now >= deadline, askedByUser: askedByUser
            )
            switch verdict {
            case .now: return true
            case .putOff: return false
            case .shielded:
                PelmetLog.log("apply: pointer never went idle — proceeding shielded")
                return true
            case .wait: try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Post-drag read that waits for the moved item to stop animating.
    private static func quiesced(_ engine: AgentBarEngine, watching key: ItemID, appState: AppState) async -> EngineSnapshot {
        try? await Task.sleep(for: AppTiming.postDragSettleFloor)
        let started = ContinuousClock.now
        var snap = await engine.snapshot()
        var matches = 0
        while matches < AppTiming.postDragQuiesceMatches,
              started.duration(to: .now) < AppTiming.postDragQuiesceCap {
            try? await Task.sleep(for: AppTiming.postDragQuiescePoll)
            let next = await engine.snapshot()
            matches = primaryFrames(next, appState: appState)[key] == primaryFrames(snap, appState: appState)[key] ? matches + 1 : 0
            snap = next
        }
        return snap
    }

    /// What a pass covers.
    enum Scope {
        /// The Apply button: the whole bar, revealed for measuring.
        case wholeBar
        /// One own item that just entered the bar (a camera indicator
        /// lighting up, a launcher's app starting): dragged to its roster
        /// slot among the items already on screen, no reveal. Own items
        /// re-enter at the slot the agent remembers, and a re-registration
        /// under the same tag keeps that slot whatever the order hint says
        /// (probed 2026-09-20), so the one door is the only way to move
        /// them — docs/CORE-SETS.md §Own items. `userAdded`: the user just
        /// added or turned it on in Settings, so the pass may expand the «.
        case ownItem(ItemID, userAdded: Bool)
        /// "Keep sections grouped" (docs/CORE-SETS.md, #80): only the given
        /// strays, icons on the wrong side of the chevron that Pelmet can
        /// explain (`StrayLedger`), cross it. No edits are read, no
        /// separator re-host, no idle extras attached, no « expanded; the
        /// bar is revealed only when a move touches a concealed icon.
        case strays(Set<ItemID>)
        /// The editor owns the order (M3, `SectionGrouper`'s keeper): only
        /// the given icons, drifted from the editor's stored order, move to
        /// their stored slots. Like `strays`: no separator re-host, no idle
        /// extras, no « expanded, and the bar is revealed only when a move
        /// touches a concealed section.
        case drift(Set<ItemID>)
        /// M5 of the same plan: no drag at all. The bar is revealed (when a
        /// concealable section is due) and the live read is folded into the
        /// given sections' stored order once (`AppState.seedOrderFromBar`).
        case seedOrder(Set<PelmetCore.Section>)

        /// A pass Pelmet starts on its own: it waits for an idle user and
        /// abandons on any input, never the shielded drag Apply gets.
        var isAutomatic: Bool {
            switch self {
            case .strays, .drift, .seedOrder: return true
            case .wholeBar, .ownItem: return false
            }
        }
    }

    /// The whole-bar plan against the stored order with every icon but
    /// `allowed` as an anchor, the way `strayPlan` plans: a filtered-out
    /// mover would have stayed a move's bound, and the drag aimed between a
    /// stray right of the « and an icon far left of it (review, 2026-10-20).
    static func driftPlan(
        for appState: AppState, snapshot snap: EngineSnapshot, allowing allowed: Set<ItemID>, remembered: Bool = false
    ) -> MovePlan.Plan {
        let facts = barFacts(for: appState, snapshot: snap, remembered: remembered)
        var plan = MovePlan.compute(
            bar: facts.bar,
            edits: appState.editorOrderTarget,
            roster: facts.roster,
            chevron: facts.chevron,
            pinned: facts.pinned,
            ownItems: Set(facts.bar).subtracting(allowed).union(unlisted(in: facts, appState: appState))
        )
        plan.skipped = plan.skipped.filter { allowed.contains($0.0) }
        return plan
    }

    /// Runs the whole pass. The caller owns `applying` and the report.
    static func run(appState: AppState, scope: Scope = .wholeBar) async -> ApplyReport {
        let engine = appState.engine
        var report = ApplyReport()
        let screenMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        // What the button counted when it was pressed. A counted icon the
        // pass then finds behind the « (the idle extras it attaches can push
        // it there) needs the « expanded like a drawn one, or the pass plans
        // nothing and the count comes straight back (Figma, 2026-09-25).
        let counted: Set<ItemID> = appState.snapshot.map {
            Set(plan(for: appState, snapshot: $0, remembered: true).moves.map(\.item))
        } ?? []

        // Hidden items have frames only under a reveal, and the plan is the
        // whole bar. Reveal everything and let the editor hold it. An own
        // item is placed among what is on screen right now.
        var revealedForPass = false
        let wholeReveal = !appState.currentRevealedSections.isSuperset(of: [.hidden, .alwaysHidden])
        switch scope {
        case .wholeBar:
            revealedForPass = wholeReveal
        case .strays(let allowed):
            // A concealed icon has no live frame, so a move that names one
            // (as the mover or as a bound) needs the reveal. A shown icon
            // crossing to the shown side, between shown neighbours, does
            // not: the bar stays shut.
            // A stray drawn into a concealable section has its drawn
            // neighbours there too (some are own extras the collapsed bar
            // does not frame): reveal to find the slot.
            if wholeReveal, let snap = appState.snapshot {
                let roster = appState.settings.sectionModel.roster
                let edits = appState.settings.orderEdits
                let drawnIntoConcealed = allowed.contains { id in
                    let section = roster.section(of: id)
                    return section != .visible && edits.order[section]?.contains(id) == true
                }
                revealedForPass = drawnIntoConcealed
                    || plan(for: appState, snapshot: snap, remembered: true, strays: allowed).moves.contains { move in
                        [move.item, move.after, move.before].compactMap { $0 }.contains { roster.section(of: $0) != .visible }
                    }
            }
        case .drift(let allowed):
            if wholeReveal, let snap = appState.snapshot {
                let roster = appState.settings.sectionModel.roster
                // Drift a full reveal saw (#171) has no move in a remembered
                // plan, which keeps Always Hidden left of Hidden: only the
                // live frames show it, so a concealed icon means a reveal.
                revealedForPass = allowed.contains { roster.section(of: $0) != .visible }
                    || driftPlan(for: appState, snapshot: snap, allowing: allowed, remembered: true).moves.contains { move in
                    [move.item, move.after, move.before].compactMap { $0 }.contains { roster.section(of: $0) != .visible }
                }
            }
        case .seedOrder(let sections):
            revealedForPass = wholeReveal && sections.contains { $0 != .visible }
        case .ownItem:
            break
        }
        if revealedForPass {
            appState.reveal([.hidden, .alwaysHidden], reason: .settingsPreview)
            try? await Task.sleep(for: AppTiming.tidyRevealWait)
        }
        // What the pass opened, the pass closes (a display set to always
        // show gets exactly its policy's reveal back).
        defer { if revealedForPass { appState.restoreDisplayPolicyAfterPass() } }
        // Separators drawn in another section re-host here, not at the
        // editor drop: a fresh registration on the new helper lands where
        // the agent puts it, and the drag below moves it into its slot.
        if case .wholeBar = scope, appState.rehostSeparatorsForApply() {
            PelmetLog.log("apply: separator host(s) moved to their drawn section")
            try? await Task.sleep(for: AppTiming.applyRehostWait)
        }
        // Idle own extras (camera off, nothing playing) join the layout
        // invisibly so the plan can move them too; they leave with the pass.
        if case .wholeBar = scope {
            let ghosts = appState.attachIdleExtrasForApply()
            if !ghosts.isEmpty {
                PelmetLog.log("apply: \(ghosts.count) idle extra(s) attached for the pass")
                // The agent lays a new item out on its own beat, and the
                // stand-ins on a bar without real buttons trail the app's
                // extras bar: a walk in between finds the counts apart and
                // names none of Pelmet's icons there (unnamed 107–570ms
                // after a show, 2026-10-13), so the plan read them all as
                // not on screen. Read until every attached extra has a frame
                // on the main bar, for as long as a reveal is given.
                let started = ContinuousClock.now
                try? await Task.sleep(for: AppTiming.postDragSettleFloor)
                while started.duration(to: .now) < AppTiming.tidyRevealWait {
                    let frames = primaryFrames(await engine.freshSnapshot(), appState: appState)
                    if ghosts.allSatisfy({ frames[$0.sectionKey] != nil }) { break }
                    try? await Task.sleep(for: AppTiming.postDragQuiescePoll)
                }
            }
        }
        defer { if case .wholeBar = scope { appState.detachIdleExtrasAfterApply() } }

        var snap = await engine.snapshot()
        appState.updateSnapshot(snap)
        // The keeper's passes read the bar live, the only read the stored
        // order may take: newcomers concealed since they came are listed
        // here (M4), and a seed pass is this read and nothing else (M5).
        if case .seedOrder(let sections) = scope {
            // A fresh walk, at rest: the cached one can be mid-reveal.
            for _ in 0..<10 {
                snap = await engine.freshSnapshot()
                if snap.itemsAtRest { break }
                try? await Task.sleep(for: AppTiming.postDragSettleFloor)
            }
            appState.updateSnapshot(snap)
            appState.slotUnlistedIcons(snap, skipping: Set(strays(for: appState, snapshot: snap, remembered: false)))
            appState.seedOrderFromBar(sections, snap: snap)
            return report
        }
        if case .drift = scope {
            appState.slotUnlistedIcons(snap, skipping: Set(strays(for: appState, snapshot: snap, remembered: false)))
        }
        // The plan for this scope, re-run on a fresh snapshot after the «
        // expands — the own-item scope must keep its filter there too, or
        // the replan is a whole-bar plan (the new separator behind the «
        // was skipped as notOnScreen for good, 2026-09-21 08:43).
        let planFor: (EngineSnapshot) -> MovePlan.Plan
        // Icons behind the « this pass is about: a whole-bar pass expands
        // for the drawn edits that name one, an own-item pass for its item.
        let trappedFor: (EngineSnapshot) -> Set<ItemID>
        switch scope {
        case .wholeBar:
            planFor = { self.plan(for: appState, snapshot: $0) }
            trappedFor = {
                trappedEdited($0, edits: appState.settings.orderEdits, appState: appState).union(trapped($0, appState: appState).intersection(counted))
            }
        case .strays(let allowed):
            planFor = { self.plan(for: appState, snapshot: $0, strays: allowed) }
            trappedFor = { _ in [] }
        case .drift(let allowed):
            planFor = { self.driftPlan(for: appState, snapshot: $0, allowing: allowed) }
            trappedFor = { _ in [] }
        case .seedOrder:
            return report
        case .ownItem(let own, let userAdded):
            // The item's section as the editor draws it counts as the edit,
            // so the plan puts the newcomer between its roster neighbours;
            // only its own move runs, the rest of the bar is not touched.
            let key = own.sectionKey
            let model = appState.settings.sectionModel
            let section = model.section(of: own)
            var edits = appState.settings.orderEdits
            if edits.order[section] == nil {
                edits.order[section] = model.order[section] ?? appState.currentOrder(in: section)
            }
            planFor = { snap in
                var plan = self.plan(for: appState, snapshot: snap, edits: edits)
                plan.moves = plan.moves.filter { $0.item == key }
                plan.skipped = plan.skipped.filter { $0.0 == key }
                return plan
            }
            // An item that came on by itself never expands the «: behind it,
            // it waits for its drawing (`ownItemsBehindOverflow`), then a
            // reveal, then Apply. On Gab's Mac all 24 expands were for own
            // items, 11 of 11 replanned 0 moves, and every « click raced
            // live mode's enter (a cover born mid-click, a « still moving):
            // 2-3s of shielded clicks for nothing, and the first one missed
            // (#150).
            // One the user just added does, like an editor move: macOS lays
            // a new item out at the bar's far left, behind the « on a full
            // bar, and a seeded agent slot doesn't move it (probed
            // 2026-11-20). Without the «, a new shortcut button sat there
            // for good (`waits for a reveal`).
            trappedFor = userAdded
                ? { ApplyPass.trapped($0, appState: appState).intersection([key]) }
                : { _ in [] }
        }
        var plan = planFor(snap)
        if case .ownItem(let own, _) = scope, plan.moves.isEmpty, plan.skipped.isEmpty {
            PelmetLog.log("apply: \(own.sectionKey.rawValue) already in its slot (own)")
            report.applied.append(own.sectionKey)
            return report
        }
        report.planned = plan.moves.count
        report.skipped = plan.skipped.map { ApplyReport.Skipped(item: $0.0, why: $0.1) }
        PelmetLog.log("apply: plan \(plan.moves.count) move(s), \(plan.skipped.count) skipped")
        for (id, why) in plan.skipped {
            PelmetLog.log("apply: skip \(id.rawValue) (\(why))")
        }
        if case .strays = scope {
            for move in plan.moves {
                let neighbours = "after \(move.after?.rawValue ?? "-"), before \(move.before?.rawValue ?? "-")"
                switch plan.placements[move.item] {
                case .drawn?:
                    PelmetLog.log("group: \(move.item.rawValue) → its drawn slot (\(neighbours))")
                case .drawnUnavailable?:
                    PelmetLog.log("group: \(move.item.rawValue) drawn slot unavailable (no drawn neighbour on screen) → chevron end (\(neighbours))")
                default:
                    PelmetLog.log("group: \(move.item.rawValue) not drawn → chevron end (\(neighbours))")
                }
            }
        }
        if case .drift = scope {
            for move in plan.moves {
                PelmetLog.log("order: \(move.item.rawValue) → its stored slot (after \(move.after?.rawValue ?? "-"), before \(move.before?.rawValue ?? "-"))")
            }
        }
        // Icons behind the « that a drawn edit names: the pass expands the
        // « (one shielded click), which gives them frames left of the
        // notch (probed 2026-09-20, drags across the notch land first try),
        // re-plans on the shifted bar, and collapses it after. Never for a
        // pass whose edits stay clear of the «.
        let trappedForPass = trappedFor(snap)
        dropAbsentSkips(&report, snap: snap, scope: scope)
        guard !plan.moves.isEmpty || !trappedForPass.isEmpty else { return report }

        if scope.isAutomatic {
            // The reveal above took over a second: idle then is not idle now.
            // A busy user means no pass at all (never the shielded drag a
            // busy pointer gets from Apply after its 8s wait): the reveal is
            // closed again by the defer above and the budget stays unspent.
            // A held button sends no input: the gate's check ran before the
            // reveal, and the recording pill's pass has no gate (#159).
            let buttonDown = NSEvent.pressedMouseButtons != 0
            guard PointerBorrow.automaticMayDrag(
                quietFor: secondsSinceAnyInput(), gap: AppTiming.applyIdleGap, buttonDown: buttonDown
            ) else {
                let why = buttonDown ? "a mouse button is held" : "input"
                if case .drift = scope {
                    PelmetLog.log("order: pass abandoned — \(why)")
                } else {
                    PelmetLog.log("group: pass abandoned — \(why)")
                }
                report.abandoned = true
                return report
            }
        } else {
            // A quiet pass (a drop on the panel) runs under a cover, and the
            // pointer is the user's, still on the panel: 8s of waiting for it
            // to rest held the bar frozen for 10s (2026-10-12).
            // An own item's pass is Pelmet's idea, whatever started the item.
            var askedByUser = true
            if case .ownItem = scope { askedByUser = false }
            guard await waitForIdlePointer(
                upTo: appState.transitions.quietApplyInFlight ? AppTiming.quietApplyIdleMaxWait : AppTiming.applyIdleMaxWait,
                askedByUser: askedByUser
            ) else {
                PelmetLog.log("apply: a mouse button is held — the drag is put off")
                report.abandoned = true
                return report
            }
        }
        // Over a full-screen app the bar is up out of sight under
        // MenuBarAgent's band, and a drag starts on the band: both tries
        // bounced, and three bounces mark the app immovable for good
        // (2026-11-21). The pass waits for the bar instead, no attempt spent.
        if ItemMover.hiddenBarCovers(hiddenBarProbe) {
            PelmetLog.log("apply: the bar is hidden over a full-screen app — the drags wait")
            report.abandoned = true
            return report
        }
        // Settings is held above the drag and re-fronted after it only when
        // it is the window the user is in (an edit dragged there, Apply
        // pressed there). Open behind another app it stays there: the order
        // keeper's pass re-fronted it over Mail while the user was typing
        // (#159, 2026-11-18).
        let holdsSettings = appState.settingsWindowVisible && SettingsWindowController.shared.isFront
        if appState.settingsWindowVisible {
            PelmetLog.log("apply: Settings \(holdsSettings ? "held above the drag" : "left where it is, not in front")")
        }
        if holdsSettings { SettingsWindowController.shared.holdAboveDrag() }
        defer {
            if holdsSettings {
                SettingsWindowController.shared.refocus()
                SettingsWindowController.shared.releaseAfterDrag()
            }
        }

        var expandedToggle: OverflowToggle.Toggle?
        if trappedForPass.isEmpty, case .wholeBar = scope {
            await OverflowToggle.collapseIfLeftExpanded()
        }
        if !trappedForPass.isEmpty {
            PelmetLog.log("apply: \(trappedForPass.count) icon(s) to move behind the « — expanding it")
            expandedToggle = await OverflowToggle.expandForPass()
            if expandedToggle != nil {
                snap = await engine.snapshot()
                appState.updateSnapshot(snap)
                plan = planFor(snap)
                report.planned = plan.moves.count
                report.skipped = plan.skipped.map { ApplyReport.Skipped(item: $0.0, why: $0.1) }
                dropAbsentSkips(&report, snap: snap, scope: scope)
                let framed = trappedForPass.filter { primaryFrames(snap, appState: appState)[$0] != nil }.count
                PelmetLog.log("apply: « expanded — \(framed)/\(trappedForPass.count) framed, replanned \(plan.moves.count) move(s), \(plan.skipped.count) skipped")
            } else {
                PelmetLog.log("apply: « not expanded — trapped icons stay skipped")
            }
        }
        // Not a defer: the collapse click needs the shielded door, so it
        // runs after the drags, before the report leaves.
        let moves = plan.moves
        let draggedLeftOfChevron = await performMoves(
            moves, appState: appState, engine: engine, screenMaxX: screenMaxX, report: &report
        )
        if let expandedToggle {
            await OverflowToggle.collapseAfterPass(expandedToggle)
        }
        // The frames the collapsed bar keeps for concealed icons are from
        // before these drags: one fresh walk re-reads every icon still out,
        // before the pass conceals again, and the rest wait for a walk at
        // rest (`AppState.rereadFramesAfterPass`).
        if draggedLeftOfChevron {
            appState.rereadFramesAfterPass(await engine.freshSnapshot())
        }
        return report
    }

    /// A point on the main display's bar, where the drags are made.
    static var hiddenBarProbe: CGPoint { CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX, y: 12) }

    /// Whether any drag started or landed left of the chevron, where it
    /// shifts the concealed icons beside it (or the chevron had no frame to
    /// tell).
    private static func performMoves(
        _ moves: [Move], appState: AppState, engine: AgentBarEngine,
        screenMaxX: CGFloat, report: inout ApplyReport
    ) async -> Bool {
        var leftOfChevron = false
        func noteDrag(from x: CGFloat, to target: CGFloat, in snap: EngineSnapshot, frames: [ItemID: CGRect]) {
            let chevronX = appState.pelmetChevronItem(in: snap).flatMap { frames[$0.id.sectionKey]?.midX }
            if chevronX.map({ min(x, target) <= $0 }) ?? true { leftOfChevron = true }
        }
        var snap = await engine.snapshot()
        // Drags in a row that bounced (the icon ended where it started)
        // while the bar has a «: on a bar that full the agent bounces them
        // all (11 drags, 24s of the pointer and a shuffled bar, live test
        // 2026-10-19 20:29). A drag that moved the icon at all resets it.
        var misses = 0
        for (index, move) in moves.enumerated() {
            if misses >= AppTiming.applyOverflowMissLimit {
                PelmetLog.log("apply: \(misses) drags in a row didn't land with the « on the bar — stopping, \(moves.count - index) move(s) left")
                report.failed.append(contentsOf: moves[index...].map(\.item))
                break
            }
            snap = await engine.snapshot()
            appState.updateSnapshot(snap)
            var frames = primaryFrames(snap, appState: appState)
            guard let frame = frames[move.item] else {
                PelmetLog.log("apply: \(move.item.rawValue) has no frame — skipped")
                report.skipped.append(.init(item: move.item, why: .notOnScreen))
                continue
            }
            func bounds(_ frames: [ItemID: CGRect]) -> (left: CGRect?, right: CGRect?) {
                (move.after.flatMap { frames[$0] }, move.before.flatMap { frames[$0] })
            }
            func inSlot(_ frames: [ItemID: CGRect]) -> Bool {
                guard let x = frames[move.item]?.midX else { return false }
                let b = bounds(frames)
                return PlacementGeometry.inSlot(x: x, leftMidX: b.left?.midX, rightMidX: b.right?.midX)
            }
            func aim(_ frames: [ItemID: CGRect]) -> CGFloat? {
                let b = bounds(frames)
                let width = frames[move.item]?.width ?? frame.width
                switch (b.left, b.right) {
                case let (l?, r?): return PlacementGeometry.betweenCentersX(left: l, right: r, screenMaxX: screenMaxX)
                case let (l?, nil): return min(l.maxX + width / 2 + 2, screenMaxX - 60)
                case let (nil, r?): return max(r.minX - width / 2 - 2, 200)
                case (nil, nil): return nil
                }
            }
            // An earlier move's reflow can have settled this one already.
            if inSlot(frames), move.after == nil || frames[move.after!] != nil, move.before == nil || frames[move.before!] != nil {
                PelmetLog.log("apply: \(move.item.rawValue) already in slot")
                report.applied.append(move.item)
                continue
            }
            guard let targetX = aim(frames) else {
                PelmetLog.log("apply: \(move.item.rawValue) has no live neighbour to aim at — failed")
                report.failed.append(move.item)
                continue
            }
            guard MenuBarGeometry.isInBand(frame), frame.midX > 0, frame.midX < screenMaxX else {
                PelmetLog.log("apply: \(move.item.rawValue) frame outside the band (\(frame)) — failed")
                report.failed.append(move.item)
                continue
            }
            PelmetLog.log("apply: drag \(move.item.rawValue) x=\(frame.midX) → \(targetX) (after \(move.after?.rawValue ?? "-"), before \(move.before?.rawValue ?? "-"))")
            let ownItem = move.item.bundleID.map(PelmetBundle.ownIDs.contains) ?? false
            noteDrag(from: frame.midX, to: targetX, in: snap, frames: frames)
            await ItemMover.cmdDrag(from: CGPoint(x: frame.midX, y: 12), to: CGPoint(x: targetX, y: 12), ownItem: ownItem)
            snap = await quiesced(engine, watching: move.item, appState: appState)
            appState.updateSnapshot(snap)
            frames = primaryFrames(snap, appState: appState)
            var landed = inSlot(frames)
            // One retry, re-aimed at the bounds as they sit after the reflow,
            // as a jump: an eased drag bounces whenever WindowServer refuses
            // the agent's window drag (ItemMover.cmdDrag), a jump lands.
            if !landed, let x = frames[move.item]?.midX, let retryX = aim(frames), abs(retryX - x) > 4 {
                PelmetLog.log("apply: retry \(move.item.rawValue) x=\(x) → \(retryX) (jump)")
                noteDrag(from: x, to: retryX, in: snap, frames: frames)
                await ItemMover.cmdDrag(from: CGPoint(x: x, y: 12), to: CGPoint(x: retryX, y: 12), ownItem: ownItem, jump: true)
                snap = await quiesced(engine, watching: move.item, appState: appState)
                appState.updateSnapshot(snap)
                frames = primaryFrames(snap, appState: appState)
                landed = inSlot(frames)
            }
            let finalX = frames[move.item]?.midX ?? -1
            PelmetLog.log("apply: \(move.item.rawValue) landed at x=\(finalX) verified=\(landed)")
            if landed {
                misses = 0
                report.applied.append(move.item)
                continue
            }
            let bounced = abs(finalX - frame.midX) < 0.5
            misses = bounced && OverflowToggle.listedToggle() != nil ? misses + 1 : 0
            // Both drags landed back at the start: the item swallowed them
            // (OpenClip, 2026-09-20 18:54, two passes). Same bounce budget as
            // placement; once marked immovable it is a bound, not a failure —
            // the edit can clear instead of offering Retry forever.
            if !ownItem, move.item.bundleID != nil, abs(finalX - frame.midX) < 0.5,
               appState.noteBounce(move.item, at: finalX) {
                report.skipped.append(.init(item: move.item, why: .pinned))
            } else {
                report.failed.append(move.item)
            }
        }
        return leftOfChevron
    }
}
