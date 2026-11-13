import CoreGraphics
import Testing
@testable import PelmetCore

@Suite struct AppleMenuCornerTests {
    // Gab's 1800pt built-in, AX probe 2026-11-13: the bar spans the screen
    // from x=0 and the Apple menu item starts at x=10.
    let barMinX: CGFloat = 0
    let appleMinX: CGFloat = 10

    @Test func theCornerStripLeftOfTheAppleMenuIsTheAppleMenus() {
        for x in [CGFloat(0), 1, 5, 9, 9.5] {
            #expect(AppleMenuCorner.holdsClick(pointX: x, barMinX: barMinX, appleMinX: appleMinX))
        }
    }

    @Test func theGlyphAndTheBarPastItAreNotTheCorner() {
        // From x=10 the hit test names the item itself, which the click path
        // already refuses; past the menus is the empty bar a click may use.
        for x in [CGFloat(10), 11, 44, 700, 1799] {
            #expect(!AppleMenuCorner.holdsClick(pointX: x, barMinX: barMinX, appleMinX: appleMinX))
        }
    }

    @Test func aBarOnAnotherDisplayClaimsOnlyItsOwnCorner() {
        // A second display right of the built-in: the strip is read from
        // that bar's own left end, not from x=0.
        #expect(AppleMenuCorner.holdsClick(pointX: 1803, barMinX: 1800, appleMinX: 1810))
        #expect(!AppleMenuCorner.holdsClick(pointX: 1795, barMinX: 1800, appleMinX: 1810))
        // And a display left of it, at negative x.
        #expect(AppleMenuCorner.holdsClick(pointX: -1796, barMinX: -1800, appleMinX: -1790))
    }

    @Test func aMirroredBarClaimsNothing() {
        // Right-to-left system language: the Apple menu sits at the far end,
        // so the inset is the width of the bar. Claiming it would kill every
        // empty-bar click left of the menus.
        #expect(!AppleMenuCorner.holdsClick(pointX: 5, barMinX: 0, appleMinX: 1756))
        #expect(!AppleMenuCorner.holdsClick(pointX: 900, barMinX: 0, appleMinX: 1756))
    }

    @Test func noItemToMeasureAgainstClaimsNothing() {
        #expect(!AppleMenuCorner.holdsClick(pointX: 2, barMinX: 0, appleMinX: nil))
        // A bar whose first item starts at its very edge leaves no strip.
        #expect(!AppleMenuCorner.holdsClick(pointX: 0, barMinX: 0, appleMinX: 0))
    }
}
