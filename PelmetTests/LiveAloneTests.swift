import AppKit
import CoreGraphics
import PelmetCore
import Testing
@testable import Pelmet

/// Live mode's icons out on their own (a show rule's Battery) are drawn from
/// the live icons, so what they show keeps up while live mode lasts:
/// `aloneLayout` places them, `aloneImage` paints their ink over the bar.
struct LiveAloneTests {
    @Test func sameWidthsKeepEveryIconWhereItWas() {
        let layout = LiveMirror.aloneLayout([(0, 26), (40, 30)], widths: [26, 30])
        #expect(layout.placed == [0, 40])
        #expect(layout.moved == 0)
    }

    @Test func aWiderIconTakesItsRoomOnTheLeft() {
        // Battery "9%" → "10%": 4pt wider. Its right end stays by the «, the
        // icon left of it keeps its gap, and the run starts 4pt further left.
        let layout = LiveMirror.aloneLayout([(2, 20), (34, 26)], widths: [20, 30])
        #expect(layout.placed == [-2, 30])
        #expect(layout.moved == -4)
    }

    @Test func aNarrowerIconGivesRoomBack() {
        let layout = LiveMirror.aloneLayout([(0, 30)], widths: [24])
        #expect(layout.placed == [6])
        #expect(layout.moved == 6)
    }

    /// Premultiplied BGRA8, one value per pixel: `(x, y) -> (grey, alpha)`.
    func image(width: Int, height: Int = 4, _ pixel: (Int, Int) -> (UInt8, UInt8)) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (grey, alpha) = pixel(x, y), p = px + (y * width + x) * 4
                p[0] = grey; p[1] = grey; p[2] = grey; p[3] = alpha
            }
        }
        return ctx.makeImage()!
    }

    func greys(_ image: CGImage) -> (Int, Int) -> UInt8 {
        let w = image.width
        let ctx = CGContext(
            data: nil, width: w, height: image.height, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: image.height))
        let px = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * image.height * 4))
        return { x, y in px[(y * w + x) * 4] }
    }

    @Test func inkComesFromTheScreenWhereTheBarHasIt() throws {
        let column = image(width: 1) { _, _ in (40, 255) }
        let seen = image(width: 10) { _, _ in (200, 255) }
        // Ink at column 5 only.
        let glyphs = image(width: 10) { x, _ in x == 5 ? (255, 255) : (0, 0) }
        let out = try #require(LiveMirror.aloneImage(column: column, width: 20, seen: seen, glyphs: glyphs,
                                                     slots: [(source: 0, target: 10, width: 10)]))
        let g = greys(out)
        #expect(out.width == 20)
        #expect(g(15, 1) == 200, "the ink, from the screen")
        #expect(g(14, 1) == 200 && g(16, 1) == 200, "1 px either side of it")
        #expect(g(12, 1) == 40, "bar elsewhere in the slot")
        #expect(g(3, 1) == 40, "bar outside every slot")
    }
}

/// An Always Hidden icon that stands among the Hidden ones: live mode's cover
/// ends left of it, so it gets a patch of its own (`LiveMirror.coverStrays`).
struct LiveStrayTests {
    func icon(_ x: CGFloat, _ width: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: width, height: 24) }

    @Test func alwaysHiddenLeftOfTheHiddenRunIsNoStray() {
        #expect(LiveMirror.strays([icon(4634, 34), icon(4780, 34)], past: 4813).isEmpty)
    }

    @Test func batteryBetweenTwoHiddenIconsIsOne() {
        // The LG, 2026-11-25 16:01:46: Hidden from 4814, Always Hidden to 4886.
        #expect(LiveMirror.strays([icon(4634, 34), icon(4852, 34)], past: 4813) == [4852...4886])
    }

    /// Which icons those are, for the keeper to put back (`SectionGrouper.liveModeStrays`).
    @Test func theStrayIsNamedForTheKeeper() {
        // The MacBook, 2026-11-26 00:12: Battery patched at 1420..1446, right
        // of Fizz, through a hockey game's Live Activity.
        let velja = ItemID(rawValue: "status:com.moises.Velja::Item-0")
        let battery = ItemID.status(bundle: "com.apple.controlcenter", title: "Battery")
        #expect(LiveMirror.strayIDs([velja, battery], [icon(1180, 26), icon(1420, 26)], past: 1400) == [battery])
        #expect(LiveMirror.strayIDs([velja, battery], [icon(1180, 26), icon(1300, 26)], past: 1400).isEmpty)
        // Same rule as the patch: the icon at the edge is not one.
        #expect(LiveMirror.strayIDs([battery], [icon(4781, 34)], past: 4813).isEmpty)
    }

    @Test func theIconAtTheEdgeItselfIsNot() {
        // Its frame reaches a point past the edge (they overlap by rounding).
        #expect(LiveMirror.strays([icon(4781, 34)], past: 4813).isEmpty)
    }

    @Test func anIconThatSlidPastTheCoversEndIsOne() {
        // The leftmost Hidden icon quit: the icon beside it took its place,
        // the cover ends where it did.
        #expect(LiveMirror.strays([icon(4790, 34)], past: 4813) == [4790...4824])
    }

    @Test func sideBySideIsOneSpanAndApartIsTwo() {
        #expect(LiveMirror.strays([icon(140, 30), icon(170, 30), icon(260, 30)], past: 100) == [140...200, 260...290])
    }

    @Test func aNarrowIconIsWideEnoughToCrop() {
        #expect(LiveMirror.strays([icon(140, 16)], past: 100) == [136...160])
    }

    @Test @MainActor func aClearedPictureHoldsNothingThere() throws {
        let image = LiveAloneTests().image(width: 40) { _, _ in (200, 255) }
        let snap = ConcealGhostOverlay.BarSnapshot(image: image, windowFrame: NSRect(x: 1000, y: 0, width: 20, height: 2), takenAt: Date())
        let out = ConcealGhostOverlay.cleared(snap, over: [1005...1010])
        let grey = LiveAloneTests().greys(out.image)
        #expect([9, 10, 19, 20].map { grey($0, 1) } == [200, 0, 0, 200])
    }
}
