// InkBox.swift
// The box around one item's own ink in its column of a keyed-out strip:
// what a panel tile centres. Pure pixel reading, so the rules are tested
// without a bar to film.

import Foundation

public enum InkBox {
    public struct Box: Equatable, Sendable {
        public let x: Int, y: Int, width: Int, height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    /// How near the crop's top or bottom a run of rows counts as at its
    /// edge. The cut already leaves the band's last point out (#127); the
    /// line a 1x 30pt bar still gave sat in the last row kept.
    static let edgeReach = 2

    /// The box around the item's own ink, padded by one pixel. `pixels` is
    /// RGBA, rows from the top. Ink is any pixel with alpha. A run of ink
    /// columns that touches the crop's edge and is see-through or narrow
    /// next to the widest run is a neighbour's capsule spilling over
    /// (Velja's, OpenClip's) and is left out. So is a run of see-through
    /// rows at the crop's top or bottom with clear rows between it and the
    /// rest: the bar's edge over what lies under it, which runs the whole
    /// column, so the box was the column down to the line and the tile
    /// centred glyph and line (#156: icons 3pt high with a line under
    /// them). Nil when the picture is blank.
    public static func bounds(_ pixels: UnsafePointer<UInt8>, width w: Int, height h: Int) -> Box? {
        guard w > 0, h > 0 else { return nil }
        func alpha(_ x: Int, _ y: Int) -> Int { Int(pixels[(y * w + x) * 4 + 3]) }

        var rowRuns: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0...h {
            let inked = y < h && (0..<w).contains { alpha($0, y) > 24 }
            if inked, start == nil { start = y }
            if !inked, let s = start { rowRuns.append(s...(y - 1)); start = nil }
        }
        let rows = rowRuns.filter { run in
            guard rowRuns.count > 1, run.lowerBound < edgeReach || run.upperBound >= h - edgeReach else { return true }
            return run.contains { y in (0..<w).contains { alpha($0, y) > 160 } }
        }.flatMap { Array($0) }

        var runs: [ClosedRange<Int>] = []
        start = nil
        for x in 0...w {
            let inked = x < w && rows.contains { alpha(x, $0) > 24 }
            if inked, start == nil { start = x }
            if !inked, let s = start { runs.append(s...(x - 1)); start = nil }
        }
        guard let widest = runs.map(\.count).max() else { return nil }
        let kept = runs.filter { run in
            guard runs.count > 1, run.lowerBound == 0 || run.upperBound == w - 1 else { return true }
            // A capsule's fill is see-through; a glyph has solid pixels.
            let solid = run.contains { x in rows.contains { alpha(x, $0) > 160 } }
            return solid && run.count * 5 >= widest * 2
        }
        guard let minX = kept.first?.lowerBound, let maxX = kept.last?.upperBound else { return nil }
        var minY = h, maxY = -1
        for y in rows where (minX...maxX).contains(where: { alpha($0, y) > 24 }) {
            minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxY >= minY else { return nil }
        let lo = max(0, minX - 1), hi = min(w - 1, maxX + 1)
        let top = max(0, minY - 1), bottom = min(h - 1, maxY + 1)
        return Box(x: lo, y: top, width: hi - lo + 1, height: bottom - top + 1)
    }
}
