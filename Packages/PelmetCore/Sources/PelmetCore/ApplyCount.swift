// ApplyCount.swift
// The number on the Apply button (AppState's `pendingMoveCount`): the moves
// a plan read off the collapsed bar finds, plus the drops it cannot see that
// a pass reaches anyway. Pure: the app reads the bar, the walk and the
// sections.

import Foundation

public enum ApplyCount {
    public struct Count: Equatable, Sendable {
        /// Dropped icons the plan could not see because the « holds them:
        /// the pass expands it.
        public var trapped: Set<ItemID>
        /// Dropped icons the plan could not see because their concealed
        /// section hides them: the pass reveals it.
        public var concealed: Set<ItemID>
        public var total: Int
    }

    /// `plan` is read off the collapsed bar (remembered frames); `trapped`
    /// is every canonical key the walk puts behind the «, leftovers
    /// included; `drawn` and `concealed` judge one icon right now
    /// (`AppState.drawnNow`, `isConcealed`).
    ///
    /// Only an icon the person dropped counts beyond the plan's moves. A
    /// concealed one is never trapped, whatever its leftover frame overlaps,
    /// and the neighbour a drop lands beside is no move: read just after a
    /// conceal, Shortcuts dropped after Sound in Hidden counted both as
    /// behind the «, "Apply (2)" for one move (live test, 2026-10-13).
    /// A drawn icon really behind the « keeps the count at 1 at least: the
    /// plan without it can find nothing to do while the pass, expanding the
    /// « for it, drags the drop beside it (review, 2026-10-13).
    /// So does a drawn drop its concealed section hides: a pending edit the
    /// pass reveals for is never "Apply" with no number. Sound dropped after
    /// Snib in a concealed Hidden read a plain "Apply", its remembered frame
    /// from before Snib's drag moved it, and the pass then found the move
    /// (live test, 2026-10-13). Only a floor: counted per drop, a real move
    /// and an out-and-back in one concealed section read "Apply (2)" for
    /// one move (review, 2026-10-13).
    /// A drop drawn back at its slot (`OrderEditSettle.dropsInPlace`) is
    /// no move, in the count or the floor: Snib's out-and-back, its frame
    /// forgotten after a pass, read "Apply (2)" beside one real move and
    /// "Apply (1)" once the grouper landed it (live test, 2026-10-13).
    /// So does a drawn drop the walk has not read since its section was
    /// concealed or shown (`isUnread`): its frame, live or remembered, is
    /// from before, and Snib dropped into a concealed Hidden read a plain
    /// "Apply" until the walk at rest 0.55s later (live test, 2026-10-13
    /// 19:24:25).
    /// `outOfPlace`: icons the last full reveal had behind the «, left of an
    /// Always Hidden one (`PlacementGeometry.hiddenBehindOverflow`, #171),
    /// dropped or not: no plan sees them, and the pass expands the « for them.
    public static func count(
        _ plan: MovePlan.Plan, edits: OrderEdits, trapped: Set<ItemID>,
        drawn: (ItemID) -> Bool, concealed: (ItemID) -> Bool,
        unread: (ItemID) -> Bool = { _ in false }, outOfPlace: Set<ItemID> = []
    ) -> Count {
        let drawnKeys = Set(edits.order.values.joined())
        let moved = edits.dropped.subtracting(OrderEditSettle.dropsInPlace(edits))
        let unseen = Set(plan.skipped.filter { $0.1 == .notOnScreen }.map(\.0)).intersection(moved)
        let hidden = unseen.filter(concealed)
        let behind = unseen.intersection(trapped).subtracting(hidden)
            .union(outOfPlace.subtracting(plan.moves.map(\.item)).subtracting(hidden))
        let total = plan.moves.count + behind.count + hidden.count
        let drawnBehind = trapped.intersection(drawnKeys).filter(drawn)
        let concealedDrop = moved.intersection(drawnKeys).contains { concealed($0) || unread($0) }
        let floor = total == 0 && (!drawnBehind.isEmpty || concealedDrop)
        return Count(trapped: behind, concealed: hidden, total: floor ? 1 : total)
    }

    /// Whether the walk has yet to read `id` the way the bar draws it now,
    /// so its frame says nothing of its slot. `drawn` is the bar now
    /// (`AppState.drawnNow`), `live` the walk's canonical keys, `concealedKeys`
    /// the walk's concealed set, `atRest` whether the walk read the bar at
    /// rest. Unread: listed live while its section is concealed (the drop's
    /// conceal is not swapped yet: Snib and Sound dropped into a concealed
    /// Hidden read "= 0" for 0.55s, live test, 2026-10-13 19:24:25 and
    /// 19:26:55), or drawn but missing from the walk while it lists it
    /// concealed (a reveal not walked yet: Vorssaint, 150ms at 19:32:01) or
    /// while the walk is inside a reflow (AX lists a revealed strip
    /// progressively). One drawn, missing from a walk at rest that does not
    /// list it concealed, has left the bar: read, nothing to wait for.
    /// Also unread: one of Pelmet's own extras shown since the last walk at
    /// rest (`shown`, see `hasWalked`), listed or not. A show is no swap, so
    /// a walk can read the bar at rest before it, and the walk behind a swap
    /// reads it joining the layout: Shortcuts moved to Visible out of a
    /// concealed Hidden read "= 0" from its show until the walk at rest
    /// 0.5s on, and so did one a reveal showed (live test, 2026-10-13
    /// 20:24:38 and 20:23:58).
    public static func isUnread(
        _ id: ItemID, drawn: (ItemID) -> Bool, live: Set<ItemID>, concealedKeys: Set<ItemID>, atRest: Bool,
        shown: Set<ItemID> = []
    ) -> Bool {
        let key = id.sectionKey
        guard drawn(key) else { return live.contains(key) }
        if shown.contains(key) { return true }
        return !live.contains(key) && (concealedKeys.contains(key) || !atRest)
    }

    /// Whether a walk has read an own extra shown at `shownAt`: the latest
    /// walk at rest (`lastRestWalk`, nil before any) was taken after the
    /// show. A swap's stamp is never at rest, and a walk at rest starts half
    /// a second past the swap whose reflow showed the extra. Not whether the
    /// snapshot in hand is at rest: read so, every later swap made an extra
    /// shown long before unread again until that swap's walk at rest
    /// (review, 2026-10-13).
    public static func hasWalked(since shownAt: Date, lastRestWalk: Date?) -> Bool {
        (lastRestWalk ?? .distantPast) > shownAt
    }

    /// Whether `id`'s concealed section is what keeps it off the bar right
    /// now. Drawn wins (an icon out on its own, one macOS will not hide);
    /// then the engine's concealed set (`concealedKeys`, canonical keys);
    /// then Pelmet's own extras, which the assertion never hides (they leave
    /// the layout by their own visibility, so the set never lists them):
    /// concealed while their section is out of view, unless idle (`wouldShow`
    /// false: off the bar whatever its section). Not the «: the walk just
    /// after a conceal still lists Shortcuts and Sound, leftovers on top of
    /// each other (live test, 2026-10-13).
    public static func isConcealed(
        _ id: ItemID, drawn: (ItemID) -> Bool, concealedKeys: Set<ItemID>,
        wouldShow: (ItemID) -> Bool, section: (ItemID) -> Section, revealed: Set<Section>
    ) -> Bool {
        let key = id.sectionKey
        if drawn(key) { return false }
        if concealedKeys.contains(key) { return true }
        guard MenuBarPolicy.isPelmetExtraID(key), wouldShow(key) else { return false }
        let home = section(key)
        return home != .visible && !revealed.contains(home)
    }
}
