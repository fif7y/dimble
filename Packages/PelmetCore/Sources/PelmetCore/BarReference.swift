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
    /// is refused. A menu bar glyph fills a third of its cell and more; a
    /// clean column, blurred by the band, leaves near nothing. 12% sits
    /// between them with room on both sides. First live pass decides whether
    /// it moves — `pass:` logs the share it measured.
    public static let inkShareLimit = 0.12

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
}
