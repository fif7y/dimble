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

    // MARK: The blank closed (`LiveMirror.gapPlan`)

    let display = ItemID(rawValue: "status:com.gab.Dimble::display")
    let sconce = ItemID(rawValue: "bundle:com.gab.Sconce")
    let next = ItemID(rawValue: "status:com.moises.Velja::Item-0")

    @Test func theIconLeftOfTheStraySlidesOverItsBlank() throws {
        // The LG, 2026-11-26 09:31: Hidden from 4780 (Dimble's display
        // icon), Sconce 4818..4856, the next Hidden icon from 4856.
        let walk = [(sconce, icon(4818, 38)), (display, icon(4780, 38)), (next, icon(4856, 30)), (battery, icon(4596, 34))]
        let plan = try #require(LiveMirror.gapPlan(walk, strays: [sconce], edge: 4780))
        #expect(plan.run == 4780...4856)
        #expect(plan.width == 38)
        #expect(plan.start == 4818)
        #expect(plan.icons == [GapPlan.Slide(id: display, from: 4780, to: 4818, width: 38)])
    }

    @Test func batterysRoomIsPartOfTheBlank() throws {
        // The LG, 2026-11-26 10:37: MenuBarAgent's Battery reads without the
        // 8pt macOS keeps either side of it; the apps' icons read with theirs.
        let agent = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.battery")
        let fizz = ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.Shortcut.F"), vors = ItemID(rawValue: "status:com.vorssaint.utils::Item-0")
        let bit = ItemID(rawValue: "status:com.bitwarden.desktop::Item-0"), snib = ItemID(rawValue: "status:app.fif7y.Snib::Item-0")
        let walk = [(fizz, icon(4814, 38)), (vors, icon(4852, 42)), (bit, icon(4894, 32)), (agent, icon(4934, 26)), (snib, icon(4968, 33))]
        let plan = try #require(LiveMirror.gapPlan(walk, strays: [agent], edge: 4814))
        #expect(plan.run == 4814...4968)
        #expect(plan.width == 42)
        #expect(plan.icons.map(\.to) == [4856, 4894, 4936])
        #expect(plan.icons.last.map { $0.to + $0.width } == 4968)
    }

    @Test func roomWiderThanAnAgentIconsClosesNothing() {
        // 20pt between an app's icon and Battery: room for an icon the walk missed.
        let agent = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.battery")
        let walk = [(display, icon(100, 30)), (agent, icon(150, 26)), (next, icon(184, 30))]
        #expect(LiveMirror.gapPlan(walk, strays: [agent], edge: 100) == nil)
    }

    @Test func everyIconLeftOfTheStraySlidesAndNoneRightOfIt() throws {
        // The MacBook: four Hidden icons, Battery among them, Vorssaint after.
        let a = ItemID(rawValue: "a"), b = ItemID(rawValue: "b"), fizz = ItemID(rawValue: "fizz")
        let walk = [(a, icon(1330, 30)), (b, icon(1360, 34)), (fizz, icon(1394, 26)), (battery, icon(1420, 26)), (next, icon(1446, 30))]
        let plan = try #require(LiveMirror.gapPlan(walk, strays: [battery], edge: 1330))
        #expect(plan.run == 1330...1446)
        #expect(plan.icons.map(\.to) == [1356, 1386, 1420])
        #expect(!plan.icons.contains { $0.id == next || $0.id == battery })
    }

    @Test func twoStraysEachMoveWhatIsLeftOfThem() throws {
        let h1 = ItemID(rawValue: "h1"), h2 = ItemID(rawValue: "h2"), s1 = ItemID(rawValue: "s1"), s2 = ItemID(rawValue: "s2")
        let walk = [(h1, icon(100, 30)), (s1, icon(130, 20)), (h2, icon(150, 30)), (s2, icon(180, 20))]
        let plan = try #require(LiveMirror.gapPlan(walk, strays: [s1, s2], edge: 100))
        #expect(plan.width == 40)
        #expect(plan.icons.map(\.to) == [140, 170])
        #expect(plan.start == 140)
    }

    @Test func anIconTheWalkMissedClosesNothing() {
        // 130..160 is an icon the walk didn't read: under a cover to the
        // stray's end it would stay hidden.
        let walk = [(display, icon(100, 30)), (sconce, icon(160, 20))]
        #expect(LiveMirror.gapPlan(walk, strays: [sconce], edge: 100) == nil)
    }

    @Test func noStrayNoPlan() {
        #expect(LiveMirror.gapPlan([(display, icon(100, 30)), (next, icon(130, 30))], strays: [], edge: 100) == nil)
        // A stray at the edge itself (not past it) leaves nothing to close.
        #expect(LiveMirror.gapPlan([(sconce, icon(100, 30))], strays: [sconce], edge: 100) == nil)
    }

    @Test func anIconCrossingTheRunsEndClosesNothing() {
        let walk = [(display, icon(100, 30)), (sconce, icon(130, 20)), (next, icon(145, 30))]
        #expect(LiveMirror.gapPlan(walk, strays: [sconce], edge: 100) == nil)
    }

    @Test func theRunMustStartAtTheEdge() {
        // The walk's leftmost Hidden icon isn't the first in the run: the
        // edge it was given is someone else's.
        let walk = [(display, icon(110, 30)), (sconce, icon(140, 20))]
        #expect(LiveMirror.gapPlan(walk, strays: [sconce], edge: 100) == nil)
    }

    @Test func aPlanIsTheSameWithinHalfAPoint() throws {
        let walk = [(display, icon(4780, 38)), (sconce, icon(4818, 38))]
        let a = try #require(LiveMirror.gapPlan(walk, strays: [sconce], edge: 4780))
        let b = try #require(LiveMirror.gapPlan([(display, icon(4780.3, 38)), (sconce, icon(4818.3, 38))], strays: [sconce], edge: 4780.3))
        let c = try #require(LiveMirror.gapPlan([(display, icon(4776, 38)), (sconce, icon(4814, 38))], strays: [sconce], edge: 4776))
        #expect(a.same(as: b))
        #expect(!a.same(as: c))
    }

    @Test func aSlotWithNoInkFailsTheFilm() {
        let glyphs = LiveAloneTests().image(width: 10) { x, _ in x == 2 ? (255, 255) : (0, 0) }
        #expect(LiveMirror.everySlotInked(glyphs, slots: [(source: 0, target: 0, width: 5)]))
        #expect(!LiveMirror.everySlotInked(glyphs, slots: [(source: 0, target: 0, width: 5), (source: 5, target: 5, width: 5)]))
    }

    @Test func faintInkIsNoIconForTheFilm() {
        let faint = LiveAloneTests().image(width: 10) { _, _ in (100, 100) }
        #expect(LiveMirror.everySlotInked(faint, slots: [(source: 0, target: 0, width: 5)]))
        #expect(!LiveMirror.everySlotInked(faint, slots: [(source: 0, target: 0, width: 5)], above: 250))
    }

    @Test func theSlidIconsArePaintedOnClear() throws {
        let clear = try #require(LiveMirror.clearColumn(height: 4, space: nil))
        let seen = LiveAloneTests().image(width: 10) { _, _ in (200, 255) }
        let glyphs = LiveAloneTests().image(width: 10) { x, _ in x == 2 ? (255, 255) : (0, 0) }
        let out = try #require(LiveMirror.aloneImage(column: clear, width: 8, seen: seen, glyphs: glyphs,
                                                     slots: [(source: 0, target: 3, width: 5)]))
        let g = LiveAloneTests().greys(out)
        #expect(g(5, 1) == 200, "the ink, moved 3 px right")
        #expect(g(0, 1) == 0 && g(7, 1) == 0, "nothing where there was no ink")
    }

    var battery: ItemID { ItemID.status(bundle: "com.apple.controlcenter", title: "Battery") }

    // MARK: The keeper's carry (`SectionGrouper.liveModeReading`)

    @Test func oneReadingInPlaceKeepsTheCarry() {
        // The LG, 2026-11-26 09:32:17: a walk as the « moved read Sconce in
        // place, the next one 4 s later among the Hidden icons again.
        let t = Date(timeIntervalSinceReferenceDate: 0)
        let first = SectionGrouper.liveModeReading([], carried: [sconce], inPlace: [:], at: t)
        #expect(first.carried == [sconce] && first.inPlace == [sconce: t] && first.dropped.isEmpty)
        let again = SectionGrouper.liveModeReading([sconce], carried: first.carried, inPlace: first.inPlace, at: t + 4)
        #expect(again.carried == [sconce] && again.inPlace.isEmpty && again.dropped.isEmpty)
    }

    @Test func aReadingInPlaceSecondsLaterTakesItBack() {
        let t = Date(timeIntervalSinceReferenceDate: 0)
        let first = SectionGrouper.liveModeReading([], carried: [sconce, battery], inPlace: [:], at: t)
        let second = SectionGrouper.liveModeReading([battery], carried: first.carried, inPlace: first.inPlace, at: t + 4)
        #expect(second.dropped == [sconce])
        #expect(second.carried == [battery] && second.inPlace.isEmpty)
    }

    @Test func twoReadingsOfOneMoveKeepTheCarry() {
        // The tick's walk and the cover's, milliseconds apart, both mid-move.
        let t = Date(timeIntervalSinceReferenceDate: 0)
        let first = SectionGrouper.liveModeReading([], carried: [sconce], inPlace: [:], at: t)
        let second = SectionGrouper.liveModeReading([], carried: first.carried, inPlace: first.inPlace, at: t + 0.3)
        #expect(second.dropped.isEmpty && second.carried == [sconce] && second.inPlace == [sconce: t])
        let third = SectionGrouper.liveModeReading([], carried: second.carried, inPlace: second.inPlace, at: t + 2.5)
        #expect(third.dropped == [sconce] && third.carried.isEmpty)
    }

    @Test func aNewStrayIsCarriedAtOnce() {
        let r = SectionGrouper.liveModeReading([sconce], carried: [], inPlace: [:], at: Date())
        #expect(r.carried == [sconce] && r.inPlace.isEmpty && r.dropped.isEmpty)
    }

    @Test @MainActor func aClearedPictureHoldsNothingThere() throws {
        let image = LiveAloneTests().image(width: 40) { _, _ in (200, 255) }
        let snap = ConcealGhostOverlay.BarSnapshot(image: image, windowFrame: NSRect(x: 1000, y: 0, width: 20, height: 2), takenAt: Date())
        let out = ConcealGhostOverlay.cleared(snap, over: [1005...1010])
        let grey = LiveAloneTests().greys(out.image)
        #expect([9, 10, 19, 20].map { grey($0, 1) } == [200, 0, 0, 200])
    }
}
