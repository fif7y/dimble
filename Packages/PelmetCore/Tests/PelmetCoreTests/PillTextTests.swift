import CoreGraphics
import Testing
@testable import PelmetCore

@Suite struct PillTextTests {
    /// A font stand-in: every character 5pt wide.
    let width: (String) -> CGFloat = { CGFloat($0.count) * 5 }

    @Test func aValueThatFitsIsDrawnWhole() {
        #expect(PillText.shown("12:04", slot: 25, width: width) == "12:04")
    }

    @Test func aScoreShowsItsScore() {
        // "Senators 1" in a frame the width of the "1" alone.
        #expect(PillText.shown("Senators 1", slot: 6, width: width) == "1")
    }

    @Test func aCountShowsItsNumber() {
        // macOS 27.3's "System & App Protection Override" pill: AX value
        // "5 apps" in an 8pt frame, and the pill shows "5" (2026-11-18).
        #expect(PillText.shown("5 apps", slot: 8, width: width) == "5")
    }

    @Test func noWordFitsKeepsTheLastWord() {
        #expect(PillText.shown("Liverpool Arsenal", slot: 4, width: width) == "Arsenal")
    }
}
