import AppKit
import CoreGraphics
import Testing
@testable import Pelmet

/// A held bar's twin is cut to the icons it hides. When they come or move
/// in live mode with the capture indicator out, the cut follows them with
/// no new picture (#108): `followPlan` is the whole decision, display-free,
/// and `iconShaped` carries it out on the glyphs filmed at the cut.
struct TwinFollowTests {
    /// A 2x picture whose first column is x=1000.
    func columns(_ frame: CGRect) -> Range<Int> { Int((frame.minX - 1000) * 2)..<Int((frame.maxX - 1000) * 2) }
    func icon(_ x: CGFloat, width: CGFloat = 22) -> CGRect { CGRect(x: x, y: 0, width: width, height: 24) }
    func plan(_ cut: [CGRect], _ now: [CGRect]) -> (moves: [(columns: Range<Int>, by: Int)], fills: [Range<Int>], gone: Int) {
        ConcealGhostOverlay.followPlan(cut: cut, now: now, scale: 2, columns: columns)
    }

    @Test func nothingMovedPlansNothing() {
        let cut = [icon(1010), icon(1040, width: 30)]
        let plan = plan(cut, cut)
        #expect(plan.moves.isEmpty && plan.fills.isEmpty && plan.gone == 0)
    }

    @Test func aRunThatShiftedMovesItsInk() {
        // Something right of the run grew 3pt: every icon in it shifts.
        let cut = [icon(1010), icon(1040, width: 30), icon(1080)]
        let plan = plan(cut, cut.map { $0.offsetBy(dx: -3, dy: 0) })
        #expect(plan.fills.isEmpty)
        #expect(plan.moves.map(\.by) == [-6, -6, -6])
        #expect(plan.moves.map(\.columns) == cut.map(columns))
        #expect(plan.gone == 0)
    }

    @Test func aNewItemIsFilled() {
        // A launched app's item lands at the run's left end; nothing moves.
        let cut = [icon(1040), icon(1080)]
        let plan = plan(cut, [icon(1010, width: 28)] + cut)
        #expect(plan.moves.isEmpty)
        #expect(plan.fills == [columns(icon(1010, width: 28))])
    }

    @Test func oneSameWidthPairIsNotARun() {
        // An app back in another slot, as wide as an icon that left: its ink
        // is as likely another icon's, so it is filled, not copied.
        let plan = plan([icon(1010), icon(1080)], [icon(1050), icon(1080)])
        #expect(plan.moves.isEmpty)
        #expect(plan.fills == [columns(icon(1050))])
        #expect(plan.gone == 1)
    }

    @Test func onlyThePartThatShiftedMoves() {
        // The third icon grew 6pt: the two left of it shift left, the one
        // right of it stays, and the grown one is filled.
        let cut = [icon(1010), icon(1040), icon(1070, width: 30), icon(1110)]
        let now = [icon(1004), icon(1034), icon(1064, width: 36), icon(1110)]
        let plan = plan(cut, now)
        #expect(plan.moves.map(\.by) == [-12, -12])
        #expect(plan.moves.map(\.columns) == [columns(icon(1010)), columns(icon(1040))])
        #expect(plan.fills == [columns(icon(1064, width: 36))])
        #expect(plan.gone == 1)
    }

    // MARK: iconShaped

    /// Premultiplied BGRA8, `alpha(x, y)` from the top-left, grey.
    func image(width: Int = 100, height: Int = 20, alpha: (Int, Int) -> UInt8) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let a = alpha(x, y), p = px + (y * width + x) * 4
                p[0] = a / 2; p[1] = a / 2; p[2] = a / 2; p[3] = a
            }
        }
        return ctx.makeImage()!
    }

    func alphas(_ image: CGImage) -> (Int, Int) -> UInt8 {
        let w = image.width
        let ctx = CGContext(
            data: nil, width: w, height: image.height, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: image.height))
        let px = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * image.height * 4))
        return { x, y in px[(y * w + x) * 4 + 3] }
    }

    var picture: CGImage { image { _, _ in 255 } }
    /// One icon's ink, columns 10..<14, rows 6..<14.
    var glyphs: CGImage { image { x, y in (10..<14).contains(x) && (6..<14).contains(y) ? 255 : 0 } }

    @Test func movedInkLandsWhereTheIconWent() throws {
        let shaped = try #require(ConcealGhostOverlay.iconShaped(picture, glyphs: glyphs, spread: 0, moving: [(10..<14, by: 6)]))
        let a = alphas(shaped.image)
        #expect(a(17, 10) == 255)
        #expect(a(19, 13) == 255)
        #expect(a(12, 10) == 255, "the old ink stays")
        #expect(a(17, 4) == 0, "only the ink's own rows")
        #expect(a(30, 10) == 0)
    }

    @Test func inkMovedOffThePictureIsDropped() throws {
        let shaped = try #require(ConcealGhostOverlay.iconShaped(picture, glyphs: glyphs, spread: 0, moving: [(10..<14, by: -12)]))
        let a = alphas(shaped.image)
        #expect(a(0, 10) == 255)
        #expect(a(1, 10) == 255)
        #expect(a(12, 10) == 255)
    }

    @Test func aFillCoversTheGlyphRowsOnly() throws {
        let shaped = try #require(ConcealGhostOverlay.iconShaped(picture, glyphs: glyphs, spread: 0, filling: [40..<50]))
        let a = alphas(shaped.image)
        #expect(a(40, 6) == 255)
        #expect(a(49, 13) == 255)
        #expect(a(45, 5) == 0)
        #expect(a(45, 14) == 0)
        #expect(a(50, 10) == 0)
    }
}
