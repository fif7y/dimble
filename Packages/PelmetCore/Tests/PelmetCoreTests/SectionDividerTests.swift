import CoreGraphics
import Testing
@testable import PelmetCore

struct SectionDividerTests {
    private func rect(_ x: CGFloat, y: CGFloat = 0, width: CGFloat = 24) -> CGRect {
        CGRect(x: x, y: y, width: width, height: 24)
    }

    @Test func separatesAlwaysHiddenFromHidden() {
        let frame = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.visible, rect(20)), (.alwaysHidden, rect(44)),
            (.alwaysHidden, rect(68)), (.hidden, rect(96)), (.visible, rect(120)),
        ])
        #expect(frame == CGRect(x: 93, y: 7, width: 2, height: 10))
    }

    // Gab's bar, 2026-11-14: a 26pt slot holding a 23pt battery next to a
    // 38pt slot holding a 14pt glyph. Centred on the slot edge the line sat
    // 5pt from one icon and 16pt from the other; centred on the slots'
    // middles, 8.5 and 13. Measured ink puts it the same 10.5 from both.
    @Test func lopsidedSlotsCentreBetweenTheInk() {
        let frame = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(1414, width: 26)), (.hidden, rect(1448, width: 38)),
        ], ink: (left: 23, right: 14))
        #expect(frame?.midX == 1449)
        // #149's screenshot: a wide glyph beside the chevron's narrow one,
        // slots touching. On the slot edge the line sat against the folder.
        let touching = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(100, width: 24)), (.hidden, rect(124, width: 24)),
        ], ink: (left: 20, right: 8))
        #expect(touching?.midX == 127)
    }

    // An item in use draws a capsule its picture leaves out (Screen
    // Mirroring: 17pt of ink in a 40pt slot). Its ink is not passed, and the
    // line stays off its slot.
    @Test func theLineStaysOffASlotThatWasNotMeasured() {
        let frame = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(100, width: 40)), (.hidden, rect(140, width: 22)),
        ], ink: (left: nil, right: 16))
        #expect(frame?.midX == 140)
        // Measured, it goes no further than 4pt in.
        let measured = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(100, width: 40)), (.hidden, rect(140, width: 22)),
        ], ink: (left: 17, right: 16))
        #expect(measured?.midX == 136)
    }

    // The chevron's own glyph is known (8pt in a 38pt slot) when its
    // neighbour's is not: the line leaves the slot edge for the wide side.
    @Test func aNarrowGlyphInAWideSlotPullsTheLineItsWay() {
        let frame = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(100, width: 24)), (.visible, rect(124, width: 38)),
        ], ink: (left: nil, right: 8))
        #expect(frame?.midX == 128)
    }

    // Gab's bar, 2026-11-14 and 2026-11-17, nothing measured: the line is
    // where the slots' middles put it, 8pt and 9pt from the two icons.
    @Test func unmeasuredNeighboursCentreOnTheirSlotsMiddles() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(1414, width: 26)), (.hidden, rect(1448, width: 38)),
        ])?.midX == 1447)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(1420, width: 26)), (.hidden, rect(1454, width: 42)),
        ])?.midX == 1454)
    }

    // With no picture to measure the line stays in the gap between the slots.
    @Test func theLineStaysBetweenTheSlotsWhenInkIsNotKnown() {
        let narrowThenWide = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(0, width: 4)), (.hidden, rect(8, width: 100)),
        ])
        #expect(narrowThenWide?.midX == 8)
        let wideThenNarrow = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(0, width: 100)), (.hidden, rect(104, width: 4)),
        ])
        #expect(wideThenNarrow?.midX == 100)
    }

    // A picture wider than its slot, or two that would overlap, is a bad
    // measurement: the line falls back to the middle of the gap.
    @Test func inkThatCannotBeRightIsNotBelieved() {
        let frame = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(100, width: 24)), (.hidden, rect(120, width: 24)),
        ], ink: (left: 60, right: 60))
        #expect(frame?.midX == 122)
    }

    // A notched display's bar is 37pt tall and so are its slots: half of
    // that stood taller than the icons (#149). The line is 10pt on any bar.
    @Test func theLineIsShorterThanTheIconsOnATallBar() {
        let tall = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, CGRect(x: 44, y: 0, width: 24, height: 37)),
            (.hidden, CGRect(x: 68, y: 0, width: 24, height: 37)),
        ])
        #expect(tall == CGRect(x: 67, y: 13.5, width: 2, height: 10))
    }

    // Always Hidden out on its own (a middle click, #149) has no Hidden
    // beside it to be told apart from.
    @Test func theDividerNeedsBothSectionsOut() {
        #expect(MenuBarGeometry.showsSectionDivider(revealed: [.hidden, .alwaysHidden]))
        #expect(!MenuBarGeometry.showsSectionDivider(revealed: [.alwaysHidden]))
        #expect(!MenuBarGeometry.showsSectionDivider(revealed: [.hidden]))
        #expect(!MenuBarGeometry.showsSectionDivider(revealed: []))
    }

    @Test func separatesFromVisibleWhenHiddenIsEmpty() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(44)), (.visible, rect(68)),
        ]) == CGRect(x: 67, y: 7, width: 2, height: 10))
    }

    @Test func noOrSingleSectionHasNoDivider() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: []) == nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.hidden, rect(44)), (.visible, rect(68))]) == nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.alwaysHidden, rect(44)), (.alwaysHidden, rect(68))]) == nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.visible, rect(20)), (.alwaysHidden, rect(44))]) == nil)
    }

    @Test func unsortedSecondaryDisplayFramesKeepTheirOrigin() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.hidden, rect(-100, y: -200)), (.alwaysHidden, rect(-124, y: -200)),
        ]) == CGRect(x: -101, y: -193, width: 2, height: 10))
    }

    @Test func toleratesAXPaddingButNotOverflowCopies() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.alwaysHidden, rect(44)), (.hidden, rect(66))]) != nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.alwaysHidden, rect(44)), (.hidden, rect(48))]) == nil)
    }

    @Test func rejectsGapsAndDifferentBands() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.alwaysHidden, rect(44)), (.hidden, rect(100))]) == nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.alwaysHidden, rect(44)), (.hidden, rect(68, y: 30))]) == nil)
    }

    @Test func displayLeftOfPrimaryKeepsItsNegativeOrigin() {
        // A display left of the built-in runs from x = -1728 to 0.
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(-1700)), (.hidden, rect(-1672)), (.visible, rect(-1644)),
        ]) == CGRect(x: -1675, y: 7, width: 2, height: 10))
    }

    @Test func overflowTrappedPairHasNoDivider() {
        // Items the native « has trapped report stacked frames, not a 24pt run.
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(1400)), (.hidden, rect(1400)),
        ]) == nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(1400)), (.hidden, rect(1412)),
        ]) == nil)
        // The same pair out on the bar is a boundary.
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(1400)), (.hidden, rect(1424)),
        ]) == CGRect(x: 1423, y: 7, width: 2, height: 10))
    }

    @Test func ignoresZeroWidthItems() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(44, width: 0)), (.hidden, rect(68)),
        ]) == nil)
    }
}
