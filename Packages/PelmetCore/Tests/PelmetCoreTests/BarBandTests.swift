import Testing
@testable import PelmetCore

@Suite struct BarBandTests {
    // A notched MacBook: safe area 38, visible band and bar window 39.
    @Test func aNotchedBarIsItsWindow() {
        #expect(BarBand.height(safe: 38, visible: 39, window: 39) == 39)
    }

    // #156: a MacBook with an Island. The safe area is 40, the bar and its
    // window 45. The band was 40, so the bar's own window was taller than
    // it and read as another app's surface.
    @Test func aBarTallerThanTheSafeAreaIsItsWindow() {
        #expect(BarBand.height(safe: 40, visible: 45, window: 45) == 45)
    }

    // #81: an external main display whose visible band is a point taller
    // than the bar window.
    @Test func aVisibleBandTallerThanTheWindowIsCutToIt() {
        #expect(BarBand.height(safe: 0, visible: 31, window: 30) == 30)
    }

    // Off the main display with no window read yet.
    @Test func withoutAWindowTheOldRuleStands() {
        #expect(BarBand.height(safe: 0, visible: 30, window: nil) == 30)
        #expect(BarBand.height(safe: 38, visible: 39, window: nil) == 39)
        #expect(BarBand.height(safe: 40, visible: 45, window: nil) == 40)
    }

    // Under a full-screen app nothing says there is a bar: the caller's own
    // fallback decides, not a window that happens to be up.
    @Test func noBandStaysNone() {
        #expect(BarBand.height(safe: 0, visible: 0, window: 39) == 0)
        #expect(BarBand.height(safe: 0, visible: 0, window: nil) == 0)
    }

    // A full-screen app on a display with a notch or an Island: the safe
    // area is all there is, and the window height is the one kept from
    // before. It never raises the band there, it can still cut it.
    @Test func aFullScreenAppKeepsTheSafeArea() {
        #expect(BarBand.height(safe: 38, visible: 0, window: 39) == 38)
        #expect(BarBand.height(safe: 40, visible: 0, window: 45) == 40)
        #expect(BarBand.height(safe: 38, visible: 0, window: 30) == 30)
    }

    @Test func theBarWindowIsNeverForeign() {
        // His built-in: a 45pt bar window over a band read at 40.
        #expect(BarBand.isBarWindow(owner: "Window Server", layer: 24, barLevel: 24, y: 0, top: 0, height: 45))
        // A display above the main one: its top is negative.
        #expect(BarBand.isBarWindow(owner: "Window Server", layer: 24, barLevel: 24, y: -113, top: -113, height: 30))
        // A pill's own rect starts below the display's top (y 7 of 45).
        #expect(BarBand.isBarWindow(owner: "Window Server", layer: 24, barLevel: 24, y: 0, top: 7, height: 45))
    }

    @Test func otherSurfacesAreNotTheBar() {
        // A notch app's panel, a pill's window, a full-screen backstop.
        #expect(!BarBand.isBarWindow(owner: "Sconce", layer: 25, barLevel: 24, y: 0, top: 0, height: 120))
        #expect(!BarBand.isBarWindow(owner: "MenuBarAgent", layer: 24, barLevel: 24, y: 0, top: 0, height: 45))
        #expect(!BarBand.isBarWindow(owner: "Window Server", layer: 24, barLevel: 24, y: 0, top: 0, height: 1133))
        #expect(!BarBand.isBarWindow(owner: "Window Server", layer: 24, barLevel: 24, y: 300, top: 0, height: 45))
    }
}
