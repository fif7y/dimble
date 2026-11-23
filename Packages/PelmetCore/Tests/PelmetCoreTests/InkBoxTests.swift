import Testing
@testable import PelmetCore

@Suite struct InkBoxTests {
    /// A column of a keyed-out strip, clear but for what `ink` paints.
    private struct Column {
        let w: Int, h: Int
        var alpha: [UInt8]

        init(_ w: Int, _ h: Int) {
            self.w = w; self.h = h
            alpha = [UInt8](repeating: 0, count: w * h)
        }

        mutating func ink(x: ClosedRange<Int>, y: ClosedRange<Int>, _ a: UInt8) {
            for row in y { for col in x { alpha[row * w + col] = a } }
        }

        var box: InkBox.Box? {
            let rgba: [UInt8] = alpha.flatMap { [0, 0, 0, $0] }
            return rgba.withUnsafeBufferPointer { InkBox.bounds($0.baseAddress!, width: w, height: h) }
        }
    }

    /// A 14-row glyph in the middle of a 1x bar's 29-row column.
    private func glyph() -> Column {
        var column = Column(30, 29)
        column.ink(x: 9...20, y: 8...21, 255)
        return column
    }

    @Test func aGlyphIsBoxedWithAPixelAround() {
        #expect(glyph().box == InkBox.Box(x: 8, y: 7, width: 14, height: 16))
    }

    // #156: a faint row across the bottom of the cut (the bar's lower edge
    // over a window, not the icon) made the box the whole column, down to
    // the line: the tile centred glyph and line, and the glyph rode 3pt high
    // with a line under it.
    @Test func aFaintLineAlongTheBottomEdgeIsNotTheGlyph() {
        var column = glyph()
        column.ink(x: 0...29, y: 28...28, 110)
        #expect(column.box == glyph().box)
    }

    @Test func aFaintLineAlongTheTopEdgeIsNotTheGlyph() {
        var column = glyph()
        column.ink(x: 0...29, y: 0...1, 110)
        #expect(column.box == glyph().box)
    }

    // A glyph's own detached part is solid: a tray under an arrow stays.
    @Test func aSolidPartAtTheEdgeStays() {
        var column = glyph()
        column.ink(x: 9...20, y: 27...28, 255)
        #expect(column.box == InkBox.Box(x: 8, y: 7, width: 14, height: 22))
    }

    // Faint ink that is part of the glyph's own rows (an antialiased foot)
    // is not cut off it.
    @Test func faintRowsJoinedToTheGlyphStay() {
        var column = Column(30, 29)
        column.ink(x: 9...20, y: 8...26, 255)
        column.ink(x: 9...20, y: 27...28, 110)
        #expect(column.box == InkBox.Box(x: 8, y: 7, width: 14, height: 22))
    }

    @Test func aNeighboursCapsuleAtTheSideIsLeftOut() {
        var column = glyph()
        column.ink(x: 0...2, y: 4...24, 60)
        #expect(column.box == glyph().box)
    }
}
