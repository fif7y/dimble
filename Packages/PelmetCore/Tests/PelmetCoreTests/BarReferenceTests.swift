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
}
