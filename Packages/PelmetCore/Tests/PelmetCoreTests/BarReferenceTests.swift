import Testing
@testable import PelmetCore

@Suite struct BarReferenceTests {
    /// A column of the band: `w` by `h`, RGBA8, top row first.
    private struct Column {
        var pixels: [UInt8]
        let w: Int, h: Int

        init(w: Int = 20, h: Int = 40, level: (Int) -> Int) {
            self.w = w; self.h = h
            pixels = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                let v = UInt8(clamping: level(y))
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
                }
            }
        }

        /// A block of ink centred in the column, as an icon's glyph sits.
        mutating func ink(width iw: Int, height ih: Int, level: UInt8 = 230) {
            for y in ((h - ih) / 2)..<((h + ih) / 2) {
                for x in ((w - iw) / 2)..<((w + iw) / 2) {
                    let i = (y * w + x) * 4
                    pixels[i] = level; pixels[i + 1] = level; pixels[i + 2] = level
                }
            }
        }

        /// A column whose bar changes across it as well as down it, as a sharp
        /// wallpaper does (#156).
        init(w: Int = 20, h: Int = 40, pixel: (Int, Int) -> Int) {
            self.init(w: w, h: h) { _ in 0 }
            for y in 0..<h {
                for x in 0..<w { paint(x..<(x + 1), y..<(y + 1), level: UInt8(clamping: pixel(x, y))) }
            }
        }

        mutating func paint(_ xs: Range<Int>, _ ys: Range<Int>, level: UInt8) {
            for y in ys {
                for x in xs {
                    let i = (y * w + x) * 4
                    pixels[i] = level; pixels[i + 1] = level; pixels[i + 2] = level
                }
            }
        }

        /// This column taken as the empty bar, `raw` as the strip filmed over it.
        func unexplained(beside raw: Column) -> Double {
            pixels.withUnsafeBufferPointer { e in
                raw.pixels.withUnsafeBufferPointer { r in
                    BarReference.unexplainedShare(empty: e.baseAddress!, raw: r.baseAddress!, width: w, height: h)
                }
            }
        }

        var share: Double { pixels.withUnsafeBufferPointer { BarReference.inkShare($0.baseAddress!, width: w, height: h) } }
        var isClean: Bool { pixels.withUnsafeBufferPointer { BarReference.isClean($0.baseAddress!, width: w, height: h) } }
    }

    @Test func aFlatBarHoldsNoInk() {
        let bar = Column { _ in 48 }
        #expect(bar.share == 0)
        #expect(bar.isClean)
    }

    // The band darkens down its own height. A flat average would read that
    // as ink; the line between the margins cancels it.
    @Test func aGradientIsStillBar() {
        let bar = Column { 60 + $0 }
        #expect(bar.share == 0)
        #expect(bar.isClean)
    }

    // #128: a visible icon standing in the column the pass filmed a hidden
    // one in. Subtracting it leaves the intruder's fragments in the tile.
    @Test func anIconInTheReferenceIsRefused() {
        var bar = Column { _ in 48 }
        bar.ink(width: 14, height: 14)
        #expect(bar.share > BarReference.inkShareLimit)
        #expect(!bar.isClean)
    }

    @Test func anIconOverAGradientIsRefusedToo() {
        var bar = Column { 60 + $0 }
        bar.ink(width: 14, height: 14)
        #expect(!bar.isClean)
    }

    // Blur, not ink: under the step, however much of the column it covers.
    @Test func blurUnderTheStepIsNotInk() {
        var bar = Column { _ in 48 }
        bar.ink(width: 20, height: 30, level: 48 + UInt8(BarReference.inkStep - 1))
        #expect(bar.share == 0)
        #expect(bar.isClean)
    }

    // The gap the limit splits, from 59 real glyphs over four bars: a hard
    // edge across the band costs about 6%, the sparsest real glyph 9.3%.
    @Test func aSparseGlyphIsRefused() {
        var bar = Column { _ in 48 }
        bar.ink(width: 8, height: 8)          // 64 of 640 = 10%
        #expect(bar.share > 0.09 && bar.share < 0.11)
        #expect(!bar.isClean)
    }

    @Test func anEdgeAcrossTheBandIsKept() {
        var bar = Column { _ in 48 }
        bar.ink(width: 20, height: 2)         // 40 of 640 = 6.25%
        #expect(bar.share > 0.06 && bar.share < 0.07)
        #expect(bar.isClean)
    }

    // A speck is not an icon: the limit leaves room for one.
    @Test func aSpeckStaysClean() {
        var bar = Column { _ in 48 }
        bar.ink(width: 4, height: 4)
        #expect(bar.share > 0)
        #expect(bar.isClean)
    }

    // Too short to keep its margins clear of a glyph: not judged.
    @Test func aColumnWithNoMarginIsNotJudged() {
        var bar = Column(w: 20, h: 8) { _ in 48 }
        bar.ink(width: 14, height: 6)
        #expect(bar.share == 0)
        #expect(bar.isClean)
    }

    // #156: a bar that draws its wallpaper sharp. A bright edge the margin
    // line can't follow reads as ink where no icon sits, and the strip
    // filmed over the same bar draws the same edge.
    private static func rows(_ x: Int, _ y: Int) -> Int { y < 20 ? 40 : 200 }    // an edge across the band, under the glyph
    private static func rim(_ x: Int, _ y: Int) -> Int { x >= 16 && (8..<32).contains(y) ? 200 : 40 }   // one beside it

    @Test func aSharpEdgeUnderTheGlyphIsTheBars() {
        let empty = Column(pixel: Self.rows)
        var raw = empty
        raw.paint(6..<14, 16..<24, level: 120)
        #expect(empty.share > BarReference.inkShareLimit)
        #expect(empty.unexplained(beside: raw) == 0)
    }

    @Test func aSharpEdgeBesideTheGlyphIsTheBars() {
        let empty = Column(pixel: Self.rim)
        var raw = empty
        raw.paint(6..<14, 16..<24, level: 230)
        #expect(empty.share > BarReference.inkShareLimit)
        #expect(empty.unexplained(beside: raw) == 0)
    }

    // #128 still refused: the strip doesn't draw what stood in the column.
    @Test func anIntruderOverAPlainBarIsUnexplained() {
        var empty = Column { _ in 48 }
        empty.ink(width: 14, height: 14)
        var raw = Column { _ in 48 }
        raw.paint(6..<14, 16..<24, level: 120)
        #expect(empty.unexplained(beside: raw) > BarReference.unexplainedLimit)
    }

    @Test func anIntruderOverASharpEdgeIsUnexplained() {
        var empty = Column(pixel: Self.rows)
        empty.ink(width: 14, height: 14)
        var raw = Column(pixel: Self.rows)
        raw.paint(6..<14, 16..<24, level: 120)
        #expect(empty.unexplained(beside: raw) > BarReference.unexplainedLimit)
    }

    // An intruder the glyph covers in its own colour agrees with the strip
    // where they overlap, and its hole doesn't.
    @Test func aRingUnderASameColourGlyphIsUnexplained() {
        var empty = Column { _ in 48 }
        empty.ink(width: 14, height: 14)
        empty.paint(5..<15, 15..<25, level: 48)
        var raw = Column { _ in 48 }
        raw.ink(width: 14, height: 14)
        #expect(empty.unexplained(beside: raw) > BarReference.unexplainedLimit)
    }

    @Test func aColumnWithNoMarginIsNotExplained() {
        let empty = Column(w: 20, h: 8) { _ in 48 }
        var raw = empty
        raw.ink(width: 14, height: 6)
        #expect(empty.unexplained(beside: raw) == 0)
    }

    // #156 at 1x: the empty bar a pixel off the strip. Its edges are the
    // bar's, not the icon's.
    private static func nearest(_ empty: Column, _ raw: Column) -> Column {
        var out = empty
        out.pixels.withUnsafeMutableBufferPointer { e in
            raw.pixels.withUnsafeBufferPointer { r in
                BarReference.nearestBar(e.baseAddress!, raw: r.baseAddress!, width: empty.w, height: empty.h)
            }
        }
        return out
    }

    private static func changed(_ a: Column, _ b: Column) -> Int {
        stride(from: 0, to: a.pixels.count, by: 4).filter { i in (0..<3).contains { abs(Int(a.pixels[i + $0]) - Int(b.pixels[i + $0])) >= 8 } }.count
    }

    @Test func anEdgeAPixelOffIsBar() {
        let empty = Column(pixel: Self.rim)
        let raw = Column { x, y in Self.rim(x + 1, y + 1) }
        #expect(Self.changed(empty, raw) > 0)
        #expect(Self.changed(Self.nearest(empty, raw), raw) == 0)
    }

    @Test func aGlyphOverAFlatBarKeepsItsBar() {
        let empty = Column { _ in 48 }
        var raw = empty
        raw.ink(width: 8, height: 8)
        #expect(Self.nearest(empty, raw).pixels == empty.pixels)
    }

    @Test func aGlyphBesideAnEdgeIsKept() {
        let empty = Column(pixel: Self.rim)
        var raw = empty
        raw.paint(6..<14, 16..<24, level: 120)
        #expect(Self.changed(Self.nearest(empty, raw), raw) == 64)
    }

    @Test func aThinLineBrighterInTheStripIsBar() {
        var empty = Column { _ in 48 }
        empty.paint(0..<20, 30..<31, level: 68)
        var raw = Column { _ in 48 }
        raw.paint(0..<20, 30..<31, level: 76)
        #expect(Self.changed(empty, raw) == 20)
        #expect(Self.changed(Self.nearest(empty, raw), raw) == 0)
    }

    @Test func aGlyphAcrossAnEdgeIsKept() {
        let empty = Column(pixel: Self.rim)
        var raw = empty
        raw.paint(12..<20, 16..<24, level: 230)
        #expect(Self.changed(Self.nearest(empty, raw), raw) == 64)
    }
}
