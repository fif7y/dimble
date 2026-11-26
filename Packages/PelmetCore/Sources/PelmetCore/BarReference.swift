// BarReference.swift
// Is the empty-bar column a glyph is cut against really bar, and nothing
// else? Pure pixel math — locked by BarReferenceTests.

/// The reference a picture pass subtracts from an item's column is meant to
/// be that column of the bar with no icon on it. It is not always: the icons
/// move between the strip the pass films and the bar the reference was taken
/// over, so a visible icon can stand in the column a hidden one is filmed in
/// (#128: Claude's starburst under Snipaste's). Subtracting that leaves
/// fragments of the intruder in the tile, and the keyed strip carries the
/// same contamination, so there is nothing to fall back to downstream: such a
/// column has to be refused before a picture is made of it.
public enum BarReference {
    /// A pixel this far off its column's own bar is not the bar. The same
    /// step `ItemPictures.flatMask` calls ink.
    public static let inkStep = 26

    /// The share of a column's middle that may read as ink before the column
    /// is refused.
    ///
    /// Measured 2026-11-11 over four real bars — Gab's three displays (a
    /// built-in at 2x and two externals at 1x, over a flat wallpaper) and the
    /// translucent bar over a photo wallpaper in #129's screenshot — by
    /// sliding a column's width across each and scoring every position:
    ///
    /// - **Bar with no icon on it reads 0.00%.** Not a median, the maximum,
    ///   on all four. The band's blur leaves nothing 26 levels off its own
    ///   margins, even with a photograph under it.
    /// - **59 real glyphs, scored on centre, run 3.3% to 36.7%.** The two
    ///   thinnest (3.3%, 3.6%) are separators. The sparsest real glyph is
    ///   9.3%, and the median is 15.8% at 2x, 21% at 1x.
    /// - The one clean-looking thing that scored at all was a hard vertical
    ///   edge inside the band (#129's stale cover boundary): 6.7% over a 2x
    ///   column. A reference with a window's edge in it is wrong anyway, so
    ///   refusing that column is right.
    ///
    /// Busier wallpapers were the obvious worry, so 22 more real bars were
    /// read off other people's screenshots on the issues — light and dark,
    /// photographs, gradients, several displays. **Empty bar never crossed
    /// the step on any of them.** Its distance from its own margin line runs
    /// 0 to 14.8 levels, median 3.8, so the busiest bar in the sample still
    /// had 11 levels of headroom under 26, and every one of them scored a
    /// 0.00% share where no icon sat. What the band does to a photograph is
    /// blur it flat; more colour in it does not change that.
    ///
    /// So the gap is 6.7% to 9.3% and 8% splits it: every glyph but a
    /// separator is caught, and nothing that is only bar is refused. It is a
    /// narrow gap — widen the sample before moving this, with
    /// `pelmet.debug.picturePass`, which logs the share of every column.
    public static let inkShareLimit = 0.08

    /// How much of the column's middle is not bar, 0 to 1.
    ///
    /// The band is blurred and no icon reaches its first and last rows, so
    /// those rows are the column's own control: a straight line between them
    /// is what the bar does in between, give or take the blur. That line
    /// costs nothing and it cancels the band's own vertical gradient, which a
    /// flat average would read as ink.
    ///
    /// `pixels` is RGBA8, top row first, `w` by `h`. A column too short to
    /// keep margins clear of a glyph is not judged, and reads as 0.
    public static func inkShare(_ pixels: UnsafePointer<UInt8>, width w: Int, height h: Int) -> Double {
        let margin = h / 10
        guard w > 0, margin >= 1, h - 2 * margin >= 2 else { return 0 }
        let topCentre = Double(margin - 1) / 2
        let bottomCentre = Double(h - 1) - Double(margin - 1) / 2
        let span = bottomCentre - topCentre
        guard span > 0 else { return 0 }
        var ink = 0
        for x in 0..<w {
            var top = (0, 0, 0), bottom = (0, 0, 0)
            for y in 0..<margin {
                let t = (y * w + x) * 4, b = ((h - 1 - y) * w + x) * 4
                top.0 += Int(pixels[t]); top.1 += Int(pixels[t + 1]); top.2 += Int(pixels[t + 2])
                bottom.0 += Int(pixels[b]); bottom.1 += Int(pixels[b + 1]); bottom.2 += Int(pixels[b + 2])
            }
            for y in margin..<(h - margin) {
                let i = (y * w + x) * 4
                let t = (Double(y) - topCentre) / span
                var off = 0
                for c in 0..<3 {
                    let a = Double(c == 0 ? top.0 : c == 1 ? top.1 : top.2) / Double(margin)
                    let z = Double(c == 0 ? bottom.0 : c == 1 ? bottom.1 : bottom.2) / Double(margin)
                    off = max(off, abs(Int((a + (z - a) * t).rounded()) - Int(pixels[i + c])))
                }
                if off >= inkStep { ink += 1 }
            }
        }
        return Double(ink) / Double(w * (h - 2 * margin))
    }

    /// True when the column looks like bar all the way down.
    public static func isClean(_ pixels: UnsafePointer<UInt8>, width w: Int, height h: Int) -> Bool {
        inkShare(pixels, width: w, height: h) < inkShareLimit
    }

    /// The share of the column's middle that `unexplainedShare` may find
    /// before a column `inkShare` refused stays refused.
    ///
    /// Not every bar blurs its wallpaper: #156's built-in draws it sharp, and
    /// a bright planet rim read 24.7% and 39.2% (Time Machine, Proton Pass)
    /// where no icon sat, which kept both tiles on their app icons. Measured
    /// 2026-11-26 on his dump (a 2x built-in, a 1x external): every column
    /// that held no intruder read 0.00%, the rim's two 0.12% at most (22
    /// columns). Intruders built from his own eleven icons, each one's glyph
    /// laid over the true empty bar under every other, centred and a quarter
    /// and a half of a column off (1,057 that put 2% of a column or more in
    /// it), read 0.59% at least at 1x and 2.0% at 2x. The worst are two round
    /// glyphs centred on each other at 1x. 0.3% sits between.
    public static let unexplainedLimit = 0.003

    /// How much of an empty-bar column differs from the filmed column in a way
    /// the bar can't explain, 0 to 1: the share of the middle that held an
    /// intruder (#128) rather than wallpaper.
    ///
    /// Where the two columns agree, both show the bar: the wallpaper the icon
    /// leaves uncovered, sharp or not. Where they differ, the filmed column
    /// has the icon's glyph and the empty one should have bar, which is what
    /// the agreeing pixels either side in the same row say it is, a straight
    /// line between them. An empty pixel off that line by `inkStep` is
    /// something the strip doesn't draw: an icon that stood there, or one the
    /// glyph covers in the same colour (its agreeing pixels then predict the
    /// rest of the glyph wrong). A row with no agreeing pixel counts whole.
    ///
    /// No margin line here: a sharp wallpaper pulls it off (#156).
    /// `empty` and `raw` are the same column, RGBA8, top row first.
    public static func unexplainedShare(empty: UnsafePointer<UInt8>, raw: UnsafePointer<UInt8>, width w: Int, height h: Int) -> Double {
        let margin = h / 10
        guard w > 0, margin >= 1, h - 2 * margin >= 2 else { return 0 }
        var agree = [Bool](repeating: false, count: w)
        var off = 0
        for y in margin..<(h - margin) {
            for x in 0..<w {
                let i = (y * w + x) * 4
                agree[x] = (0..<3).allSatisfy { abs(Int(empty[i + $0]) - Int(raw[i + $0])) < inkStep }
            }
            for x in 0..<w where !agree[x] {
                let left = stride(from: x - 1, through: 0, by: -1).first { agree[$0] }
                let right = (x + 1..<w).first { agree[$0] }
                guard left != nil || right != nil else { off += 1; continue }
                let i = (y * w + x) * 4
                var apart = 0
                for c in 0..<3 {
                    let line: Double
                    if let left, let right {
                        let t = Double(x - left) / Double(right - left)
                        line = Double(empty[(y * w + left) * 4 + c]) * (1 - t) + Double(empty[(y * w + right) * 4 + c]) * t
                    } else {
                        line = Double(empty[(y * w + (left ?? right!)) * 4 + c])
                    }
                    apart = max(apart, abs(Int(line.rounded()) - Int(empty[i + c])))
                }
                if apart >= inkStep { off += 1 }
            }
        }
        return Double(off) / Double(w * (h - 2 * margin))
    }

    /// How far past its neighbours' range `nearestBar` lets a filmed pixel
    /// stay bar: a glyph next to an edge in the bar loses that much at most.
    public static let nearestBarGive = 8

    /// Moves each empty-bar pixel, channel by channel, to the value nearest
    /// the filmed one in the range the bar's pixels within one of it span,
    /// widened by that range again, `nearestBarGive` at most. In place.
    ///
    /// The empty bar can sit a fraction of a pixel off the strip it is
    /// subtracted from: #156's 1x external drew a planet rim's soft edge 8 to
    /// 25 levels apart in the two, and its last row up to 26 apart in every
    /// column. Too faint to count as ink, but a picture's mask takes its
    /// alpha from that distance over the glyph's core, so faint streaks
    /// followed the rim, and the tile's box widened to the whole column. A
    /// filmed pixel the bar draws within a pixel of where it stands is bar.
    /// A thin line half a pixel over changes its own peak too: one on the
    /// same rim stood 14 levels over its row in the strip and 6 in the empty
    /// bar, caught on one pixel in one and split over two in the other, so
    /// the range is widened by itself. Over a blurred bar the neighbours
    /// agree to a level or two and nothing moves, and a glyph is far from
    /// all of them.
    ///
    /// `empty` and `raw` are the same column, RGBA8, top row first.
    public static func nearestBar(_ empty: UnsafeMutablePointer<UInt8>, raw: UnsafePointer<UInt8>, width w: Int, height h: Int) {
        guard w > 0, h > 0 else { return }
        let bar = Array(UnsafeBufferPointer(start: empty, count: w * h * 4))
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                for c in 0..<3 {
                    var lo = 255, hi = 0
                    for yy in max(y - 1, 0)...min(y + 1, h - 1) {
                        for xx in max(x - 1, 0)...min(x + 1, w - 1) {
                            let v = Int(bar[(yy * w + xx) * 4 + c])
                            lo = min(lo, v); hi = max(hi, v)
                        }
                    }
                    let give = min(hi - lo, nearestBarGive)
                    empty[i + c] = UInt8(clamping: min(max(Int(raw[i + c]), lo - give), hi + give))
                }
            }
        }
    }
}
