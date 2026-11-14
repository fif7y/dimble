// PlacementGeometry.swift
// Pure neighbour math for Apply's ⌘-drags (see ApplyPass for the
// measurement/verification context) — locked by PlacementGeometryTests.

import CoreGraphics

public enum PlacementGeometry {
    /// Center on the click, clamped to the display's margins near either edge.
    public static func centeredPanelX(pointerX: CGFloat, width: CGFloat,
                                      screenMinX: CGFloat, screenMaxX: CGFloat,
                                      margin: CGFloat) -> CGFloat {
        let minX = screenMinX + margin
        // A panel wider than the display less both margins would put the
        // far bound left of the near one and the clamp would invert.
        let maxX = max(screenMaxX - margin - width, minX)
        return min(max(pointerX - width / 2, minX), maxX)
    }

    /// Post-drag order check: the item must sit right of its left neighbor
    /// and left of its right one (mids pre-filtered to the item's band;
    /// a missing neighbor imposes no bound).
    public static func inSlot(x: CGFloat, leftMidX: CGFloat?, rightMidX: CGFloat?) -> Bool {
        if let leftMidX, x < leftMidX { return false }
        if let rightMidX, x > rightMidX { return false }
        return true
    }

    /// Target when both slot bounds are live: the midpoint of the bounds'
    /// CENTERS, from raw frames. Valid even when packed icons leave no edge
    /// gap — the drop only needs to land between the mids for the agent to
    /// slot between them (over a day of drags every between-centers drop
    /// landed, 2026-09-09). Hot-corner floor (200) and trailing clamp
    /// (maxX−60) keep the drop off the corners.
    public static func betweenCentersX(left: CGRect, right: CGRect, screenMaxX: CGFloat) -> CGFloat {
        min(max((left.midX + right.midX) / 2, 200), screenMaxX - 60)
    }

    /// Primary-display band membership: an AX walk can carry another
    /// display's bar (its own coordinate origin).
    public static func isPrimary(_ f: CGRect, screenMaxX: CGFloat) -> Bool {
        MenuBarGeometry.isInBand(f) && f.midX > 0 && f.midX < screenMaxX
    }

    /// Indices of the frames the native « holds. Trapped items report
    /// frames that overlap each other: one shared minX (2026-08-21: 8
    /// trapped separators at exactly one x) or staggered 5–6pt apart
    /// (2026-09-21: Velja 1044–1081, DBngin 1049–1073, a separator
    /// 1055–1081, the first real icon at 1087). Real neighbours overlap
    /// by at most ~2pt of AX padding (OpenClip 1087+36 next to Herd at
    /// 1121); phantoms by 18pt and more.
    public static func overflowTrapped(_ frames: [CGRect]) -> Set<Int> {
        let tolerance: CGFloat = 4
        var trapped = Set<Int>()
        for (i, a) in frames.enumerated() {
            for (j, b) in frames.enumerated() where j != i
                && min(a.maxX, b.maxX) - max(a.minX, b.minX) > tolerance {
                trapped.insert(i)
                break
            }
        }
        return trapped
    }

    /// `overflowTrapped` over a walk that still lists frames the bar no
    /// longer draws (`drawn[i]` false: an own item collapsing in place, an
    /// icon its section's conceal just put away). Such a frame never makes a
    /// drawn one read as behind the «: an idle Camera & mic collapsing onto
    /// the chevron took the chevron off the bar for every plan and stray
    /// read (2026-10-12). It is itself trapped wherever it overlaps, as before.
    public static func overflowTrapped(_ frames: [CGRect], drawn: [Bool]) -> Set<Int> {
        let shown = frames.indices.filter { drawn[$0] }
        let amongShown = overflowTrapped(shown.map { frames[$0] }).map { shown[$0] }
        return overflowTrapped(frames).filter { !drawn[$0] }.union(amongShown)
    }

    /// How many measured items the native « has trapped. The editor's
    /// overflow note reads this.
    public static func overflowTrappedCount(_ frames: [CGRect]) -> Int {
        overflowTrapped(frames).count
    }
}
