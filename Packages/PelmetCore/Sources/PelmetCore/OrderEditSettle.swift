// OrderEditSettle.swift
// Which pending order edits the bar already satisfies, so they are no edit
// any more (AppState's `pruneSettledOrderEdits`): an icon dragged out of a
// section and back to its slot lit Apply for a zero-move pass (Timer,
// 2026-09-20 21:45). Pure: the app reads the bar and the walk.

import Foundation

public enum OrderEditSettle {
    /// The sections whose drawing the bar matches in full.
    ///
    /// - `bar`: canonical keys left to right, every icon the bar can place:
    ///   live frames, plus the remembered frame of a concealed icon
    ///   (`ApplyPass.rememberedFrames`).
    /// - `live`: the walk's icons; `concealed`: the engine's concealed set
    ///   (out of the AX tree, still on the bar).
    /// - `ownBehindOverflow`: own items (canonical keys) the last walk that
    ///   saw them live found behind the «.
    /// - `ownExtras`: Pelmet's extras (canonical keys) that are on the bar
    ///   whenever their section is out: not idle, whatever the walk sees.
    /// - `itemsAtRest`: `live` was read with the bar at rest
    ///   (`EngineSnapshot.itemsAtRest`).
    public static func settledSections(
        _ edits: OrderEdits, bar: [ItemID], live: Set<ItemID>, concealed: Set<ItemID>,
        ownBehindOverflow: Set<ItemID> = [], ownExtras: Set<ItemID> = [],
        itemsAtRest: Bool = true, roster: Roster
    ) -> Set<Section> {
        // A swap stamps the mirror on the walk before it, and the walk
        // behind the swap reads the reflow a part at a time: icons it just
        // revealed have left the concealed set and are not all walked yet,
        // so they read as off the bar. Judged there, a drawing compared over
        // what was left: Shortcuts reordered in a concealed Hidden, and the
        // edit cleared the moment Hidden came out (live test, 2026-10-13).
        // The walk at rest half a second on judges instead.
        // The drawn-back shortcut below waits too: it reads no frame, but it
        // compares through the same on-bar filter, and mid-reveal that
        // filter left Shortcuts alone on both sides of a real reorder.
        guard itemsAtRest else { return [] }
        // Pelmet's own items hide by their own visibility. One a helper drew
        // once and let go stays in the concealed set with no frame (helper
        // bundles are never pruned as stale): counted, its section stayed
        // pending and Apply lit for good. Like an idle extra, it is on the
        // bar where it is live or a frame remembers it, or where it was last
        // seen behind the « (no frame is remembered there, and a reorder of
        // only that separator cleared at once).
        // An extra that is not idle is on the bar all the same: concealed
        // with its section it is neither live nor in the concealed set, and
        // a reorder of Shortcuts in a concealed Hidden cleared at the drop,
        // past the crossing guard below too (live test, 2026-10-13).
        let placed = Set(bar)
        let onBar = Set(live.map(\.sectionKey)).union(ownExtras).union(
            concealed.filter { id in
                !(id.bundleID.map(PelmetBundle.ownIDs.contains) ?? false)
                    || placed.contains(id.sectionKey) || ownBehindOverflow.contains(id.sectionKey)
            }.map(\.sectionKey)
        )
        // Relative order says nothing about the chevron: an icon drawn into
        // Hidden but still on the Visible side matched its drawing, the edit
        // cleared before the grouper ran, and it went to the chevron end
        // instead of its drawn slot (vorssaint, Snib, 2026-10-07). A drop
        // between sections stays unsettled until a pass lands it
        // (`previousSection` cleared), so its section's drawing waits.
        // So does the section it left: its baseline is where Discard puts
        // the icon back. Cleared first, Vorssaint moved out of a concealed
        // Hidden beside Snib's out-and-back would have come back with no
        // slot and been drawn last (live test, 2026-10-13 18:14:44).
        let crossing = Set(edits.previousSection.keys)
        let left = Set(edits.previousSection.values)
        var settled: Set<Section> = []
        for (section, allDrawn) in edits.order where !left.contains(section) {
            // An icon not on the bar at all (its app not running, an idle
            // extra) is no edit, as Apply drops it (`dropAbsentSkips`):
            // counted, it kept the drawing pending and Apply lit after the
            // grouper had placed everything (Today, Figma, four idle
            // separators, 2026-10-07).
            // A separator this edit made is on its way to the bar, whether or
            // not the walk has named it yet: it waits for the pass that
            // places it. Two of three made in a concealed Always Hidden
            // stayed at the bar's far left, their edit cleared as the bar's
            // own order (live test, 2026-11-24 12:37).
            let drawn = allDrawn.filter { onBar.contains($0.sectionKey) || edits.created.contains($0.sectionKey) }
            let drawnSet = Set(drawn)
            guard drawnSet.isDisjoint(with: crossing) else { continue }
            let placed = bar.filter { roster.section(of: $0) == section }
            // A drawn icon the bar cannot place (behind the «, or concealed
            // and never framed since launch) is exactly what the edit is
            // about: it stays pending until a pass can reach it. Counted
            // absent, a reorder in a section not revealed since launch
            // compared nothing with nothing and cleared, and Apply never lit
            // (Always Hidden, 2026-10-13; Velja, Pure Paste, Unclutter,
            // DBngin, 2026-09-21; Battery, Wi-Fi, 2026-10-12).
            // Drawn back to the order the edit started from (dragged out and
            // back), it is no edit, whoever the unplaced icons are: an extra
            // its concealed section hides, waiting for a frame, lit Apply
            // until the next reveal (review, 2026-10-13), and so did a
            // third-party icon concealed with no frame: Snib dragged out and
            // back in a concealed Hidden kept Discard and a plain "Apply" lit
            // until Hidden came out (live test, 2026-10-13). The icons the
            // bar does place still have to match.
            // The baseline is read over the icons still drawn here: one a
            // pass moved out (its crossing landed) is no longer this
            // section's. Counted, Vorssaint moved from Hidden to Visible
            // kept Snib's out-and-back in Hidden pending once the grouper
            // landed it, a ghost "Apply (1)" until an Apply moved nothing
            // (live test, 2026-10-13 18:14:47).
            let unplaced = drawnSet.subtracting(placed)
            if !unplaced.isEmpty {
                guard unplaced.isDisjoint(with: edits.created), edits.previousOrder[section]?.filter(drawnSet.contains) == drawn else { continue }
            }
            if placed.filter(drawnSet.contains) == drawn.filter({ !unplaced.contains($0) }) { settled.insert(section) }
        }
        return settled
    }

    /// The dropped icons drawn back where their section's edit found them:
    /// the same neighbours in the drawing as in the baseline
    /// (`previousOrder`), read over the icons both list. No move, so no
    /// count (`ApplyCount`): a pass had forgotten Snib's frame, and its
    /// out-and-back beside a real move in a concealed Hidden read
    /// "Apply (2)", then "Apply (1)" once the move landed (live test,
    /// 2026-10-13 18:14:44). An icon that left or joined the section is
    /// that icon's move, not its neighbour's; one new to the section is
    /// never in place.
    public static func dropsInPlace(_ edits: OrderEdits) -> Set<ItemID> {
        var inPlace: Set<ItemID> = []
        for (section, allDrawn) in edits.order {
            guard let previous = edits.previousOrder[section] else { continue }
            let drawnSet = Set(allDrawn), previousSet = Set(previous)
            let drawing = allDrawn.filter(previousSet.contains)
            let baseline = previous.filter(drawnSet.contains)
            for (i, key) in drawing.enumerated() where edits.dropped.contains(key) {
                guard let j = baseline.firstIndex(of: key) else { continue }
                let left = (i > 0 ? drawing[i - 1] : nil, j > 0 ? baseline[j - 1] : nil)
                let right = (drawing.indices.contains(i + 1) ? drawing[i + 1] : nil,
                             baseline.indices.contains(j + 1) ? baseline[j + 1] : nil)
                if left.0 == left.1, right.0 == right.1 { inPlace.insert(key) }
            }
        }
        return inPlace
    }
}
