// SectionGrouper.swift
// "Keep sections grouped" (docs/CORE-SETS.md, #80). Pelmet hides by
// membership and the bar's physical order is the truth, so an icon whose
// side of the chevron disagrees with its section (a relaunched app macOS put
// on the wrong side, an editor drop across sections: membership changed,
// nothing moved) looks fine collapsed and reappears on the wrong side at
// the next reveal, shifting the visible icons. This watches for those
// strays and relocates only them through the Apply door
// (`ApplyPass.Scope.strays`: input idle, cursor hidden, input suppressed).
//
// Only a stray Pelmet can explain is moved (`StrayLedger`): one newly seen,
// relaunched, or whose section changed while its side did not. An icon whose
// side flipped by hand (a user ⌘-drag BarAdoption could not read, a drop from
// another display) stays where the user put it. Never re-sorts within a
// section, never reads the pending editor `OrderEdits`. Bounded:
// `StrayBudget` allows two attempts per item and section, then the item is
// left to the editor's "not in place" badge and Apply. On by default; the
// escape hatch is the `pelmet.keepSectionsGrouped` bool (false = no
// synthetic drag outside Apply).
//
// The editor owns the order (vault plan "Dimble editor owns the bar order",
// 2026-10-20): with no stray left, the keeper (`keepOrder`, M3) puts icons
// that drifted from the editor's stored order back in their stored slots,
// through the same door (`ApplyPass.Scope.drift`). It waits for the drift to
// settle, keeps passes apart, and gives each icon two tries per stored order
// before leaving it to Apply. Pelmet's own extras come and go and are placed
// when they show, so of its own items only separators are kept. A newcomer
// the stored order doesn't list is listed where it sits first (M4,
// `AppState.slotUnlistedIcons`, live frames only), and the first drift
// after the update is read live into the stored order instead of moved (M5,
// `ApplyPass.Scope.seedOrder`).
//
// Logging: a state is logged once per change (`group: no strays`,
// `group: N stray(s) …`, `group: waiting — <why>`, `order: drift …`,
// `order: waiting — <why>`), so a blocked pass is never silent and a quiet
// bar is not noisy.

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class SectionGrouper {
    static let defaultsKey = "pelmet.keepSectionsGrouped"
    /// Missing = on: no Settings UI, the key is the escape hatch.
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    private weak var appState: AppState?
    private var pending: Task<Void, Never>?
    /// When the first change not yet checked arrived (see `groupingMaxWait`).
    private var changedSince: ContinuousClock.Instant?
    private var lastRoster: Roster?
    private var budget = StrayBudget()
    private var ledger = StrayLedger()
    /// What the last pass tried to move: their side flips are ours.
    private var ownMoves: Set<ItemID> = []
    private var passRunning = false
    private var lastState = ""
    private var lastWaiting: String?
    private var lastDrift = ""
    /// The pid behind each icon at the last look, to tell a relaunch.
    private var driftPIDs: [ItemID: Int32] = [:]
    /// The keeper's tries, kept per stored order: a new drawing starts over.
    private var driftBudget = StrayBudget()
    private var driftTarget: [Section: [ItemID]]?
    /// The drift the keeper is waiting out, and since when it read the same.
    private var driftSeen: (ids: Set<ItemID>, since: ContinuousClock.Instant)?
    private var lastDriftPass: ContinuousClock.Instant?
    private var lastDriftWaiting: String?
    /// Drift read while Hidden and Always Hidden were both out, the one time
    /// all their icons have live frames. At rest the remembered frames keep
    /// Always Hidden left of Hidden (`FrameMemory`), so an icon standing
    /// among the other section's reads as no drift the moment the bar shuts,
    /// and the keeper, which waits out a reveal the user opened, never saw it
    /// again: a double-click kept showing Battery right of a Hidden icon
    /// (#171, 2026-11-23). Carried until a full reveal reads again, a pass
    /// moves it, or its tries run out.
    private var seenAtFullReveal: Set<ItemID> = []
    private var lastCarried = ""
    private var lastLiftWaiting: String?
    private var observers: [NSObjectProtocol] = []
    private var menuDepth = 0
    private var menuBeganAt: Date?
    private var menuEndedAt: Date?

    init(appState: AppState) {
        self.appState = appState
    }

    /// AppKit posts these for every menu this process tracks: the status
    /// item's and separators' context menus, Settings' pop-up pickers.
    func start() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.menuDepth == 0 { self.menuBeganAt = .now }
                    self.menuDepth += 1
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuDepth = max(0, self.menuDepth - 1)
                    if self.menuDepth == 0 { self.menuEndedAt = .now }
                }
            },
        ]
        // A sleeping display or a locked screen is waited out here, not
        // polled every 2s all night (`groupingGate`).
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let why = notification.name.rawValue
                MainActor.assumeIsolated { self?.awoke(why) }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Self.screenUnlocked, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.awoke("screen unlocked") }
        })
        if !Self.isOn { note("group: off (\(Self.defaultsKey))") }
    }

    private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    /// The display woke or the screen unlocked: a pass waiting on either
    /// looks again.
    private func awoke(_ why: String) {
        guard let waiting = lastWaiting ?? lastDriftWaiting else { return }
        PelmetLog.log("group: \(why) — looking again (was waiting: \(waiting))")
        noteChange()
    }

    /// A menu is tracking, or just was (it fades for a beat). A depth that
    /// never came back down is not trusted past five minutes.
    var menuIsOpen: Bool {
        if menuDepth > 0, let began = menuBeganAt, Date.now.timeIntervalSince(began) < 300 { return true }
        if let ended = menuEndedAt, Date.now.timeIntervalSince(ended) < AppTiming.groupingMenuHold { return true }
        return false
    }

    /// The owner of an on-screen window at the pop-up-menu level, from any
    /// process: another app's open menu (or a popover-menu ItemPress opened)
    /// that no notification of ours announces. Narrow like the band
    /// monitor's elevated-window test: visible and menu-sized, since helper
    /// apps keep invisible windows at high levels.
    static func popUpMenuOwner() -> String? {
        guard let list = ConcealGhostOverlay.onScreenWindows() else { return nil }
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == level,
                  // Our own windows at this level — the panel's drag ghost,
                  // the chevron's context menu — are not another app's menu.
                  (w[kCGWindowOwnerPID as String] as? pid_t) != ProcessInfo.processInfo.processIdentifier,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"], width > 20, height > 12
            else { continue }
            return w[kCGWindowOwnerName as String] as? String ?? "pid \(w[kCGWindowOwnerPID as String] ?? "?")"
        }
        return nil
    }

    /// The owner of a tooltip hanging from the menu bar. A tooltip is the
    /// orphan one level above an open menu: take the icon off the bar while
    /// its tooltip shows and the app never hears the pointer leave, so the
    /// tooltip stays up at the icon's old spot — measured 2026-11-14 with a
    /// status item of our own, still up 5s after the pointer had left the
    /// bar entirely, where the same tooltip clears inside 2s if the item
    /// stays (#148). Nothing else in the rehide gate can see one: tooltips
    /// sit two levels above `.popUpMenuWindow`, past the 24...102 the
    /// band monitor's pointer test walks and above the level this file's
    /// `popUpMenuOwner` matches.
    ///
    /// Band-local, unlike `popUpMenuOwner`: tooltips happen all over the
    /// screen all day, and one deep inside some app's window is not the
    /// bar's business — only a tooltip whose top edge hangs from a display's
    /// own band counts, or every hover in Xcode would pin the bar open.
    static func barTooltipOwner() -> String? {
        guard let list = ConcealGhostOverlay.onScreenWindows(),
              let primary = NSScreen.screens.first else { return nil }
        // Two above `.popUpMenuWindow` (so 103), which has no window-level
        // key of its own. Measured, not derived.
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2
        // A bar tooltip's top edge sits just under the icon, which on a
        // notched display is INSIDE the band (31pt into a 39pt band,
        // measured) — so the window the band allows reaches from each
        // display's top edge to a little below its band.
        let slack: CGFloat = 12
        // CG window bounds are top-left-origin global coordinates.
        let bands: [(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>)] = NSScreen.screens.map {
            let top = primary.frame.maxY - $0.frame.maxY
            let bandHeight = $0.frame.maxY - $0.visibleFrame.maxY
            return ($0.frame.minX...$0.frame.maxX, (top - 1)...(top + bandHeight + slack))
        }
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == level,
                  // Our own tooltips — Settings, the panel — are ours to
                  // clear, and must not hold the bar open.
                  (w[kCGWindowOwnerPID as String] as? pid_t) != ProcessInfo.processInfo.processIdentifier,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"],
                  let width = b["Width"], let height = b["Height"],
                  width > 20, height > 12,
                  bands.contains(where: { $0.x.contains(x) && $0.y.contains(y) })
            else { continue }
            return w[kCGWindowOwnerName as String] as? String ?? "pid \(w[kCGWindowOwnerPID as String] ?? "?")"
        }
        return nil
    }

    /// The roster was assigned: look again only if it actually changed.
    /// The budget sees every change, not only the ones a check finds a stray
    /// under: a drop to Hidden and back between two placements left
    /// Vorssaint's spent attempt standing, and the third round gave up (live
    /// test, 2026-10-13 20:17:52).
    func noteRoster(_ roster: Roster) {
        guard roster != lastRoster else { return }
        lastRoster = roster
        budget.observe(roster)
        noteChange()
    }

    /// The bar or the roster changed: look again once it has been quiet, and
    /// at the latest `groupingMaxWait` after the first change nobody has
    /// looked at yet.
    func noteChange() {
        guard Self.isOn else {
            pending?.cancel()
            pending = nil
            note("group: off (\(Self.defaultsKey))")
            return
        }
        let now = ContinuousClock.now
        let first = changedSince ?? now
        changedSince = first
        let left = AppTiming.groupingMaxWait - first.duration(to: now)
        schedule(after: min(AppTiming.groupingDebounce, max(.zero, left)))
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await check()
        }
    }

    private func note(_ line: String) {
        guard line != lastState else { return }
        lastState = line
        PelmetLog.log(line)
    }

    private func check() async {
        // The pass below must not be cancelled by the snapshots it causes:
        // `noteChange` cancels `pending`, and a cancelled sleep inside the
        // pass returns at once.
        pending = nil
        changedSince = nil
        guard !passRunning else { return }
        guard Self.isOn, let appState, let snap = appState.snapshot else { return }
        guard appState.pelmetChevronItem(in: snap) != nil else {
            note("group: no chevron on the bar — nothing to group against")
            return
        }
        // A Live Activities lift (#106) has the system's extras and pills in
        // the bar until its re-hide settles: an order read of it is no
        // drift of the user's (`order: drift` fired mid-lift, 2026-10-27),
        // and nothing is moved against it. Said once, looked at on the beat:
        // the gate is the lift's own state, gone with its re-hide.
        if let lift = appState.liftHoldReason {
            if lastLiftWaiting != lift {
                lastLiftWaiting = lift
                PelmetLog.log("order: waiting — \(lift)")
            }
            schedule(after: AppTiming.groupingDebounce)
            return
        }
        lastLiftWaiting = nil
        // Sides read now are not where the icons sit: look on the beat.
        guard !appState.barInFlux else {
            schedule(after: AppTiming.groupingDebounce)
            return
        }
        let roster = appState.settings.sectionModel.roster
        lastRoster = roster
        let strays = ApplyPass.strays(for: appState, snapshot: snap)
        // Looks first, so a flip is judged against the last look and not
        // against what this check is about to do.
        let byHand = ledger.observe(
            ApplyPass.sightings(for: appState, snapshot: snap), strays: Set(strays), ownMoves: ownMoves
        )
        ownMoves = []
        // A newcomer is listed where it sits (M4) before the order is read:
        // never drift.
        appState.slotUnlistedIcons(snap, skipping: Set(strays))
        // A stray is grouped above or left where the user put it, never
        // kept to its stored slot from here.
        let drift = carryFullRevealDrift(appState, snap, read: noteDrift(appState, snap)).filter { !strays.contains($0) }
        for id in byHand where strays.contains(id) {
            PelmetLog.log("group: \(id.rawValue) moved by hand — left where it is")
        }
        let verdict = budget.check(ledger.actionable(strays), roster: roster)
        if !verdict.newlyExhausted.isEmpty {
            PelmetLog.log("group: giving up on [\(Self.names(verdict.newlyExhausted))] after \(budget.limit) attempts — left to Apply")
        }
        guard !strays.isEmpty else {
            lastWaiting = nil
            note("group: no strays")
            await keepOrder(appState, drift: drift)
            return
        }
        let ready = verdict.ready
        guard !ready.isEmpty else {
            lastWaiting = nil
            // Each stray's own reason: "by hand, or out of attempts" stood
            // for a Vorssaint that was neither (live test, 2026-10-13 21:14:08).
            let exhausted = Set(verdict.exhausted)
            let why = strays.map { "\($0.rawValue) \(ledger.whyNotMoved($0, exhausted: exhausted))" }.joined(separator: "; ")
            note("group: \(strays.count) stray(s) [\(Self.names(strays))] — none to move: \(why)")
            await keepOrder(appState, drift: drift)
            return
        }
        note("group: \(ready.count) stray(s) [\(Self.names(ready))]")
        if let gate = appState.groupingGate() {
            if lastWaiting != gate.why {
                lastWaiting = gate.why
                PelmetLog.log("group: waiting — \(gate.why)")
            }
            // Transient gates clear on their own: look again on the beat.
            // The others end with a snapshot or roster change, a wake or an
            // unlock (`awoke`).
            if gate.transient { schedule(after: AppTiming.groupingDebounce) }
            return
        }
        lastWaiting = nil
        PelmetLog.log("group: relocating [\(Self.names(ready))] (attempt \(budget.used(ready[0], roster: roster) + 1)/\(budget.limit))")
        lastState = ""
        // The bar moves under the drift being waited out: it settles anew.
        driftSeen = nil
        passRunning = true
        ownMoves = Set(ready)
        let report = await appState.runGroupingPass(.strays(Set(ready)))
        passRunning = false
        guard let report, !report.abandoned else {
            // Nothing was dragged (an Apply pass has the bar, or the user
            // came back): not our flips, and no attempt spent.
            ownMoves = []
            schedule(after: AppTiming.groupingDebounce)
            return
        }
        budget.spend(ready, roster: roster)
        PelmetLog.log("group: pass applied=\(report.applied.count) failed=\(report.failed.count) skipped=\(report.skipped.count)")
        // Look again: a second attempt for what stayed, or "no strays".
        schedule(after: AppTiming.groupingDebounce)
    }

    /// What a pass against the editor's stored order would move right now
    /// (M0 of the editor-owns-order plan), logged on change with why each
    /// icon is off: the keeper acts on it. Remembered frames stand in for
    /// concealed icons, so Always Hidden drift among Hidden reads only at a
    /// full reveal.
    private func noteDrift(_ appState: AppState, _ snap: EngineSnapshot) -> [ItemID] {
        let plan = ApplyPass.plan(for: appState, snapshot: snap, edits: appState.editorOrderTarget, remembered: true, anchorUnlisted: true)
        var pids: [ItemID: Int32] = [:]
        for item in snap.items where item.pid > 0 { pids[item.id.sectionKey] = item.pid }
        let live = Set(snap.items.filter { $0.frame != nil }.map(\.id.sectionKey))
        let drawn = appState.settings.orderEdits
        let moves = plan.moves.map { move -> String in
            let id = move.item
            var why = id.bundleID.map(PelmetBundle.ownIDs.contains) == true ? "own"
                : MenuBarPolicy.systemItem(for: id) != nil ? "system" : "app"
            if let then = driftPIDs[id], let now = pids[id], then != now { why += ", relaunched" }
            if drawn.touches(id) { why += ", drawn" }
            if !live.contains(id) { why += ", remembered" }
            return "\(Self.names([id])) (\(why))"
        }
        driftPIDs.merge(pids) { _, now in now }
        let line = moves.isEmpty ? "order: no drift" : "order: drift \(moves.count) move(s) — \(moves.joined(separator: "; "))"
        if line != lastDrift {
            lastDrift = line
            PelmetLog.log(line)
        }
        return plan.moves.map(\.item)
    }

    /// The drift read now, plus what the last full reveal saw out of order
    /// that a read at rest can't (`seenAtFullReveal`).
    private func carryFullRevealDrift(_ appState: AppState, _ snap: EngineSnapshot, read: [ItemID]) -> [ItemID] {
        if appState.currentRevealedSections.isSuperset(of: [.hidden, .alwaysHidden]) {
            seenAtFullReveal = Set(read)
            lastCarried = ""
            appState.noteHiddenBehindOverflow(snap)
            return read
        }
        let carried = seenAtFullReveal.subtracting(read).sorted { $0.rawValue < $1.rawValue }
        let line = carried.isEmpty ? "" : "order: carrying [\(Self.names(carried))] — out of order at the last full reveal"
        if line != lastCarried {
            lastCarried = line
            if !line.isEmpty { PelmetLog.log(line) }
        }
        return read + carried
    }

    /// M3, the keeper: drift from the stored order goes back to its stored
    /// slots through the grouper's door. The drift must read the same for
    /// `driftSettle` first, passes are `driftCooldown` apart, and an icon
    /// gets `driftBudget.limit` tries per stored order before it is left to
    /// Apply's count. A pass that finds nothing to move once the bar is out
    /// (a remembered frame that was stale) spends its try all the same, so a
    /// false reading can't reveal the bar again and again.
    private func keepOrder(_ appState: AppState, drift: [ItemID]) async {
        let model = appState.settings.sectionModel
        if model.order != driftTarget {
            // A newcomer slotted in (M4) is no new target for the icons
            // already listed: two fresh tries each per new app was two more
            // reveals for an icon WindowServer won't let move (review).
            let grew = driftTarget.map { old in
                old.allSatisfy { section, before in
                    (model.order[section] ?? []).filter(Set(before).contains) == before
                }
            } ?? false
            if !grew { driftBudget = StrayBudget() }
            driftTarget = model.order
        }
        // A separator drawn into another section moves with its host, which
        // only Apply re-hosts: dragged first, it would sit left of the «
        // still hosted for Visible and show collapsed.
        let rehostPending = appState.separatorsNeedRehost
        // An icon its section's order doesn't list yet has no stored slot:
        // it waits to be listed where it sits (M4), never dragged.
        let candidates = drift.filter { id in
            guard model.order[model.section(of: id)]?.contains(id) == true else { return false }
            guard id.bundleID.map(PelmetBundle.ownIDs.contains) == true else { return true }
            return id.isPelmetSeparator && !rehostPending
        }
        let verdict = driftBudget.check(candidates, roster: model.roster)
        if !verdict.newlyExhausted.isEmpty {
            PelmetLog.log("order: giving up on [\(Self.names(verdict.newlyExhausted))] after \(driftBudget.limit) attempts — left to Apply")
            seenAtFullReveal.subtract(verdict.newlyExhausted)
        }
        let ready = verdict.ready
        guard !ready.isEmpty else {
            driftSeen = nil
            lastDriftWaiting = nil
            return
        }
        let now = ContinuousClock.now
        guard let seen = driftSeen, seen.ids == Set(ready) else {
            driftSeen = (Set(ready), now)
            schedule(after: AppTiming.driftSettle)
            return
        }
        let steady = seen.since.duration(to: now)
        guard steady >= AppTiming.driftSettle else {
            schedule(after: AppTiming.driftSettle - steady)
            return
        }
        if let last = lastDriftPass, last.duration(to: now) < AppTiming.driftCooldown {
            schedule(after: AppTiming.driftCooldown - last.duration(to: now))
            return
        }
        if let gate = appState.groupingGate() {
            if lastDriftWaiting != gate.why {
                lastDriftWaiting = gate.why
                PelmetLog.log("order: waiting — \(gate.why)")
            }
            if gate.transient { schedule(after: AppTiming.groupingDebounce) }
            return
        }
        lastDriftWaiting = nil
        // M5: the first drift in a section not yet taken from the bar is the
        // bar the user had. A seed pass reads it live into the stored order
        // of every such section, and nothing moves.
        let unseeded = appState.unseededOrderSections
        if ready.contains(where: { unseeded.contains(model.section(of: $0)) }) {
            PelmetLog.log("order: seeding [\(unseeded.map(\.rawValue).sorted().joined(separator: ", "))] from the bar — drift [\(Self.names(ready))] not moved")
            passRunning = true
            let report = await appState.runGroupingPass(.seedOrder(unseeded))
            passRunning = false
            // Like a pass: its reveal holds the cooldown.
            if report != nil { lastDriftPass = .now }
            driftSeen = nil
            schedule(after: AppTiming.groupingDebounce)
            return
        }
        PelmetLog.log("order: keeping [\(Self.names(ready))] (attempt \(driftBudget.used(ready[0], roster: model.roster) + 1)/\(driftBudget.limit))")
        passRunning = true
        ownMoves = Set(ready)
        let report = await appState.runGroupingPass(.drift(Set(ready)))
        passRunning = false
        guard let report, !report.abandoned else {
            ownMoves = []
            // Abandoned after its reveal (input during the wait): the
            // cooldown holds, or a user pausing every 2s saw the bar open
            // and shut on every pause (review, 2026-10-20).
            if report != nil { lastDriftPass = .now }
            schedule(after: AppTiming.groupingDebounce)
            return
        }
        lastDriftPass = .now
        driftSeen = nil
        driftBudget.spend(ready, roster: model.roster)
        seenAtFullReveal.subtract(report.applied)
        PelmetLog.log("order: pass applied=\(report.applied.count) failed=\(report.failed.count) skipped=\(report.skipped.count)")
        schedule(after: AppTiming.groupingDebounce)
    }

    private static func names(_ ids: [ItemID]) -> String {
        ids.map(\.rawValue).joined(separator: ", ")
    }
}
